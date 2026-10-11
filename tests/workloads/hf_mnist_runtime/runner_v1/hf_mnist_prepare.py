from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,struct,time,urllib.request
import numpy as np

root=Path('tests/workloads/hf_mnist_runtime');assets=root/'assets'
assets.mkdir(parents=True,exist_ok=True)
def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def request(url):
    return urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'EnergyElastic-workload/1.0'}),timeout=60)
def fetch(url,name,expected=None):
    p=assets/name
    if p.exists():
        if expected and sha(p)!=expected:raise RuntimeError('Saved asset checksum mismatch: '+name)
        print('Reusing:',name,flush=True);return p
    tmp=p.with_suffix(p.suffix+'.partial');print('Downloading:',name,flush=True)
    total=0;last=time.monotonic()
    with request(url) as r,tmp.open('wb') as f:
        for b in iter(lambda:r.read(262144),b''):
            f.write(b);total+=len(b)
            if time.monotonic()-last>10:print(f'{name}: {total/1048576:.1f} MiB',flush=True);last=time.monotonic()
    if expected and sha(tmp)!=expected:raise RuntimeError('Downloaded asset checksum mismatch: '+name)
    tmp.replace(p);return p
rev='cb3a98271dcbb8cca33bab1981aa4be6b9bbb507'
model=fetch(f'https://huggingface.co/dacorvo/mnist-mlp/resolve/{rev}/model.safetensors',
    'model.safetensors','59dfd2968fc0c60192c8e41ecff29f9271ec625684c9c3368ceae4166d089aec')
revision_file=assets/'dataset_revision.json'
if revision_file.exists():drev=json.loads(revision_file.read_text())['sha']
else:
    with request('https://huggingface.co/api/datasets/dmitva/the-mnist-database/revision/main') as r:drev=json.load(r)['sha']
    revision_file.write_text(json.dumps({'sha':drev})+'\n')
if len(drev)!=40 or any(c not in '0123456789abcdef' for c in drev):raise RuntimeError('Dataset revision')
files={}
for name in ('train-images.idx3-ubyte','train-labels.idx1-ubyte','t10k-images.idx3-ubyte','t10k-labels.idx1-ubyte'):
    expected={'train-images.idx3-ubyte':'ba891046e6505d7aadcbbe25680a0738ad16aec93bde7f9b65e87a2fc25776db',
      't10k-images.idx3-ubyte':'0fa7898d509279e482958e8ce81c8e77db3f2f8254e26661ceb7762c4d494ce7'}.get(name)
    files[name]=fetch(f'https://huggingface.co/datasets/dmitva/the-mnist-database/resolve/{drev}/{name}',name,expected)
raw=model.read_bytes();size=struct.unpack('<Q',raw[:8])[0]
if size>1000000 or 8+size>len(raw):raise RuntimeError('Safetensors header')
header=json.loads(raw[8:8+size]);weights={}
expected_shapes={'input_layer.weight':[256,784],'input_layer.bias':[256],
    'mid_layer.weight':[256,256],'mid_layer.bias':[256],
    'output_layer.weight':[10,256],'output_layer.bias':[10]}
if set(header)-{'__metadata__'}!=set(expected_shapes):raise RuntimeError('Unexpected pretrained tensors')
for name,shape in expected_shapes.items():
    q=header[name];lo,hi=q['data_offsets']
    if q['dtype']!='F32' or q['shape']!=shape or hi-lo!=4*np.prod(shape) or not 0<=lo<=hi<=len(raw)-8-size:
        raise RuntimeError('Tensor layout: '+name)
    weights[name]=np.frombuffer(raw,dtype='<f4',count=int(np.prod(shape)),offset=8+size+lo).reshape(shape).copy()
    if not np.isfinite(weights[name]).all():raise RuntimeError('Nonfinite weights')
def images(p,count):
    with p.open('rb') as f:magic,n,h,w=struct.unpack('>IIII',f.read(16))
    if (magic,n,h,w)!=(2051,count,28,28) or p.stat().st_size!=16+count*784:raise RuntimeError('Image IDX')
    return np.memmap(p,dtype=np.uint8,mode='r',offset=16,shape=(count,784))
def labels(p,count):
    b=p.read_bytes();magic,n=struct.unpack('>II',b[:8])
    if (magic,n)!=(2049,count) or len(b)!=8+count:raise RuntimeError('Label IDX')
    y=np.frombuffer(b[8:],np.uint8).astype(np.int64)
    if set(y.tolist())!=set(range(10)):raise RuntimeError('Label classes')
    return y
x=images(files['train-images.idx3-ubyte'],60000);y=labels(files['train-labels.idx1-ubyte'],60000)
xt=images(files['t10k-images.idx3-ubyte'],10000);yt=labels(files['t10k-labels.idx1-ubyte'],10000)
rng=np.random.default_rng(20261010);fit=[];val=[]
for cls in range(10):
    ids=np.flatnonzero(y==cls);rng.shuffle(ids);val.extend(ids[:500]);fit.extend(ids[500:])
fit=np.asarray(fit);val=np.asarray(val);rng.shuffle(fit);rng.shuffle(val)
work=root/('run_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'));work.mkdir()
np.savez(work/'pretrained.npz',**weights)
np.savez(work/'indices.npz',train=fit,validation=val,test=np.arange(10000))
m=dict(model='dacorvo/mnist-mlp',model_revision=rev,model_sha256=sha(model),
    dataset='dmitva/the-mnist-database',dataset_revision=drev,
    files={k:{'path':str(p),'sha256':sha(p)} for k,p in files.items()},
    split_counts={'train':len(fit),'validation':len(val),'test':len(yt)},
    normalization='(pixel/255 - 0.1307)/0.3081',seed=20261010,
    note='Validation held out for this fine-tuning run; original pretraining split provenance is not established.',
    pretrained_sha256=sha(work/'pretrained.npz'),indices_sha256=sha(work/'indices.npz'),
    hardware_training_started=False)
(work/'assets_manifest.json').write_text(json.dumps(m,indent=2)+'\n')
(root/'current_run.json').write_text(json.dumps({'work':str(work)})+'\n')
print('HF MODEL + REAL MNIST READY:',m['split_counts'],flush=True)
print('Model: 784 -> 256 -> 256 -> 10; 269322 parameters.',flush=True)
print('Work directory:',work,flush=True)
print('No training results claimed at this stage.',flush=True)
