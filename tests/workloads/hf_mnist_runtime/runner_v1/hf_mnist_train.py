from pathlib import Path
import json,hashlib,resource
import numpy as np
from hf_rtl_backend import RTL,sha

root=Path('tests/workloads/hf_mnist_runtime')
work=Path(json.loads((root/'current_run.json').read_text())['work'])
assets=json.loads((work/'assets_manifest.json').read_text())
rtl=json.loads((work/'rtl_manifest.json').read_text())
for p,h in rtl['active_source_hashes'].items():
    if sha(p)!=h:raise SystemExit('RTL changed: '+p)
if sha(rtl['closed_manifest'])!=rtl['closed_manifest_sha256'] or sha(rtl['binary'])!=rtl['binary_sha256']:
    raise SystemExit('Closed checkpoint or compiled simulator changed.')
if sha(Path(__file__).parent/'hf_rtl_backend.py')!=rtl['backend_sha256']:
    raise SystemExit('Workload backend changed.')
if sha(work/'pretrained.npz')!=assets['pretrained_sha256'] or sha(work/'indices.npz')!=assets['indices_sha256']:
    raise SystemExit('Prepared weights or splits changed.')
for item in assets['files'].values():
    if sha(item['path'])!=item['sha256']:raise SystemExit('MNIST asset changed.')
w=np.load(work/'pretrained.npz',allow_pickle=False)
W1=w['input_layer.weight'].T.copy();b1=w['input_layer.bias'].copy()
W2=w['mid_layer.weight'].T.copy();b2=w['mid_layer.bias'].copy()
base=w['output_layer.weight'].T.copy();bias0=w['output_layer.bias'].copy()
ix=np.load(work/'indices.npz',allow_pickle=False)
def data(split):
    prefix='t10k' if split=='test' else 'train';N=10000 if split=='test' else 60000
    xp=assets['files'][prefix+'-images.idx3-ubyte']['path']
    yp=assets['files'][prefix+'-labels.idx1-ubyte']['path']
    return np.memmap(xp,np.uint8,'r',offset=16,shape=(N,784)),np.frombuffer(Path(yp).read_bytes()[8:],np.uint8)
seen=set();sets={};rng=np.random.default_rng(20261010)
for split in ('train','validation','test'):
    x,y=data(split);ids=ix[split];selected=[]
    for cls in range(10):
        pool=ids[y[ids]==cls].copy();rng.shuffle(pool);count=0
        for i in pool:
            key=hashlib.sha256(x[i].tobytes()).digest()
            if key in seen:continue
            seen.add(key);selected.append(int(i));count+=1
            if count==4:break
        if count!=4:raise RuntimeError('Insufficient unique pilot images')
    rng.shuffle(selected);selected=np.asarray(selected)
    sets[split]=((x[selected].astype(np.float32)/255-np.float32(.1307))/np.float32(.3081),y[selected].astype(int))
    np.save(work/(split+'_pilot_indices.npy'),selected)
print('Real-workload pilot: 40 train / 40 validation / 40 test, balanced and image-disjoint.',flush=True)
print('Pretrained encoder frozen; eight classifier LoRA blocks, rank up to 8.',flush=True)
print('All network forward layers and adapter gradient GEMMs use full-system RTL.',flush=True)
print('Host: normalization, ReLU, softmax/loss, SGD and adapter weight assembly.',flush=True)
print('Budget trace is emulated. Power/energy are not measured by this run.',flush=True)

def softmax(z):
    e=np.exp(z-z.max(axis=1,keepdims=True));return e/e.sum(axis=1,keepdims=True)
def stats(z,y):
    p=softmax(z);return {'loss':float(-np.log(np.maximum(p[np.arange(len(y)),y],1e-30)).mean()),
                        'accuracy':float((p.argmax(axis=1)==y).mean()),'samples':len(y)}
def forward(x,W,b,gemm):
    h=np.maximum(gemm(x,W1)+b1,0)
    h=np.maximum(gemm(h,W2)+b2,0)
    return gemm(h,W)+b,h
def assembled(A,B):
    W=base.copy()
    for block in range(8):W[block*32:(block+1)*32]+=A[block]@B[block]
    return W
def evaluate(engine,x,y,W,b):
    logits=[]
    for off in range(0,len(x),4):
        z,_=forward(x[off:off+4],W,b,engine.gemm);logits.append(z)
        print(f'RTL evaluation: {min(off+4,len(x))}/{len(x)} images',flush=True)
    return stats(np.concatenate(logits),y)
history=[];report=dict(stage='running',model=assets['model'],dataset=assets['dataset'],
    execution='Full-system RTL forward and adapter-gradient GEMMs; host-assisted classifier LoRA fine-tuning',
    full_model_training=False,complete_benchmark_suite=False,
    live_telemetry_switch_stress_tested=False,loss_feedback_governor_tested=False,
    pixel_disjoint_pilot_counts={k:len(v[1]) for k,v in sets.items()},
    telemetry='emulated budget trace',workload_power_measured=False,
    BF16_oracle='FP32 dot2 reference, tolerance four FP32 ULP; host FP32 reduction across beats',
    host_adapter_assembly=True,quantization_gradient='straight-through estimator',history=history)
(work/'training_report.json').write_text(json.dumps(report,indent=2)+'\n')
engine=RTL(rtl['binary'],work)
try:
    # Small fractional real-value probes before allowing any training updates.
    a=np.arange(32,dtype=np.float32).reshape(4,8)/16-1
    b=np.arange(32,dtype=np.float32).reshape(8,4)/32-.5
    policies={0:(2,15,8,1,8,1),650:(1,7,4,2,4,1),890:(0,3,2,4,2,1),1024:(0,1,1,16,1,0)}
    for used,want in policies.items():
        policy=engine.config(used)
        if tuple(policy[:6])!=want:raise RuntimeError('Unexpected governor policy: '+str(policy))
        engine.gemm(a,b)
        print('FULL-SYSTEM KERNEL + POLICY PASS:',used,policy[:6],flush=True)
    engine.config(650)
    xv,yv=sets['validation'];xc,yc=sets['train']
    z,_=forward(xv,base,bias0,lambda a,b:a@b)
    report['cpu_reference_validation']=stats(z,yv)
    report['rtl_initial_validation']=evaluate(engine,xv,yv,base,bias0)
    print('CPU FP32 reference:',report['cpu_reference_validation'],flush=True)
    print('RTL INT8 initial validation:',report['rtl_initial_validation'],flush=True)
    # Paired runs share pretrained weights, adapter initialization and minibatch order.
    init=np.random.default_rng(99).normal(0,.01,(8,32,8)).astype(np.float32)
    for variant in ('fixed_int8','adaptive'):
        A=init.copy();B=np.zeros((8,8,10),np.float32);bias=bias0.copy();last_update=-10**9;updates=0
        for batch,off in enumerate(range(0,len(xc),4)):
            used=650 if variant=='fixed_int8' else (650,890,0,1024)[batch%4]
            policy=engine.config(used);mode,mask,rank,interval,scope,train,now=policy
            oldA=A.copy();oldB=B.copy();oldbias=bias.copy()
            W=assembled(A,B);z,h=forward(xc[off:off+4],W,bias,engine.gemm)
            y=yc[off:off+4];metrics=stats(z,y)
            do_update=bool(train and now-last_update>=interval)
            blocks=[]
            if do_update:
                dz=softmax(z);dz[np.arange(len(y)),y]-=1;dz/=len(y)
                G=engine.gemm(h.T,dz)
                blocks=[(batch*scope+j)%8 for j in range(scope)]
                for block in blocks:
                    g=G[block*32:(block+1)*32]
                    da=engine.gemm(g,oldB[block,:rank].T)
                    db=engine.gemm(oldA[block,:,:rank].T,g)
                    # Finite, bounded SGD update; inactive ranks/blocks remain exact.
                    da=np.clip(da,-1,1);db=np.clip(db,-1,1)
                    A[block,:,:rank]-=np.float32(.02)*da
                    B[block,:rank]-=np.float32(.02)*db
                bias-=np.float32(.02)*dz.sum(axis=0);updates+=1
                last_update=engine.last_cycle
            for block in range(8):
                if block not in blocks:
                    if not np.array_equal(A[block],oldA[block]) or not np.array_equal(B[block],oldB[block]):
                        raise RuntimeError('Inactive scope changed')
                elif not np.array_equal(A[block,:,rank:],oldA[block,:,rank:]) or not np.array_equal(B[block,rank:],oldB[block,rank:]):
                    raise RuntimeError('Inactive rank changed')
            if not do_update and (not np.array_equal(A,oldA) or not np.array_equal(B,oldB) or not np.array_equal(bias,oldbias)):
                raise RuntimeError('Frozen training parameters changed')
            if not all(np.isfinite(v).all() for v in (A,B,bias)):raise RuntimeError('Nonfinite training state')
            row=dict(variant=variant,batch=batch,mode=mode,rank=rank,scope=scope,interval_cycles=interval,
                     training_enabled=bool(train),weight_update=do_update,**metrics)
            history.append(row);np.savez(work/(variant+'_checkpoint.npz'),A=A,B=B,bias=bias)
            (work/'training_report.json').write_text(json.dumps(report,indent=2)+'\n')
            print('RTL TRAIN:',row,flush=True)
        if not updates or not np.any(B):raise RuntimeError('No learned adapter weights')
        engine.config(650);W=assembled(A,B)
        report[variant+'_validation']=evaluate(engine,xv,yv,W,bias)
        # No hyperparameter or checkpoint selection using test labels.
        xt,yt=sets['test'];report[variant+'_test']=evaluate(engine,xt,yt,W,bias)
        report[variant+'_updates']=updates
        print(variant,'VALIDATION',report[variant+'_validation'],'TEST',report[variant+'_test'],flush=True)
    report.update(stage='pilot_complete',rtl_kernel_calls=engine.calls,rtl_tiles=engine.tiles,
      rtl_checked_values=engine.checked,rtl_job_cycles=engine.cycles,
      mapped_period_ns=rtl['period_ns'],full_model_training=False,complete_benchmark_suite=False,
      critical_freeze_and_rank_scope_preservation_passed=True,
      update_interval_effect_demonstrated=False)
    for p,h in rtl['active_source_hashes'].items():
        if sha(p)!=h:raise RuntimeError('RTL source changed during pilot: '+p)
    (work/'training_report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('REAL HF MODEL RTL TRAINING PILOT PASS:',work/'training_report.json',flush=True)
    print('Pilot accuracy uses only 40 held-out test images; it is not a full MNIST benchmark.',flush=True)
except Exception as exc:
    report.update(stage='failed',error=str(exc),rtl_kernel_calls=engine.calls,rtl_checked_values=engine.checked)
    (work/'training_report.json').write_text(json.dumps(report,indent=2)+'\n');raise
finally:engine.close()
