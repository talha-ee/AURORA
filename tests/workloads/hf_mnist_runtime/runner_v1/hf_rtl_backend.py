from pathlib import Path
import json, hashlib, math, queue, struct, subprocess, threading, time, resource
import numpy as np

def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()

class RTL:
    def __init__(self, binary, work, vvp='vvp'):
        self.work=Path(work);self.calls=0;self.cycles=0;self.tiles=0;self.checked=0
        self.q=queue.Queue();self.log=(self.work/'rtl.log').open('w')
        def limited():resource.setrlimit(resource.RLIMIT_AS,(2*1024**3,2*1024**3))
        self.p=subprocess.Popen([vvp,str(binary)],stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1,preexec_fn=limited)
        self.last_cycle=0
        def reader():
            for line in self.p.stdout:
                self.log.write(line);self.q.put(line.strip())
            self.q.put(None)
        threading.Thread(target=reader,daemon=True).start()
        self.line('EE_READY')
    def line(self,prefix):
        end=time.monotonic()+1800
        while time.monotonic()<end:
            try:line=self.q.get(timeout=15)
            except queue.Empty:
                print('RTL running; simulator RAM stays bounded.',flush=True);continue
            if line is None:raise RuntimeError('RTL stopped; see '+str(self.work/'rtl.log'))
            if line.startswith(('FATAL','ERROR')):raise RuntimeError(line)
            if line.startswith(prefix):return line.split()
            if line.startswith('EE_'):raise RuntimeError('Unexpected RTL response: '+line)
        raise TimeoutError('RTL wall-clock timeout; see rtl.log')
    def send(self,text):
        self.p.stdin.write(text+'\n');self.p.stdin.flush()
    def config(self,used):
        self.send('C '+str(used));v=list(map(int,self.line('EE_CONFIG')[1:]))
        self.mode=v[0];self.policy=v;self.last_cycle=v[6]
        return v
    def close(self):
        if self.p.poll() is None:
            self.send('Q')
            try:self.p.wait(timeout=15)
            except subprocess.TimeoutExpired:self.p.kill();self.p.wait()
        self.log.close()
    def gemm(self,a,b):
        a=np.asarray(a,np.float32);b=np.asarray(b,np.float32)
        m,k=a.shape;k2,n=b.shape
        if k!=k2 or min(m,k,n)<1 or not np.isfinite(a).all() or not np.isfinite(b).all():
            raise ValueError('Invalid GEMM')
        self.calls+=1;mode=self.mode
        M=(m+3)//4*4;N=(n+3)//4*4
        lanes=2 if mode==2 else (8 if mode==0 else 4)
        K=(k+lanes-1)//lanes*lanes
        A=np.zeros((M,K),np.float32);B=np.zeros((K,N),np.float32)
        A[:m,:k]=a;B[:k,:n]=b
        if mode==2:
            def bf(x):
                u=x.view(np.uint32).copy()
                u+=np.uint32(0x7fff)+(u>>16 & 1)
                return (u>>16).astype(np.uint16)
            A=bf(A);B=bf(B);scale=1.
            def floats(x):return (x.astype(np.uint32)<<16).view(np.float32)
            AF=floats(A);BF=floats(B)
            beats=8*(K//2)
        else:
            qmax=7 if mode==0 else 127
            sa=max(float(np.max(np.abs(A))),1e-30)/qmax
            sb=max(float(np.max(np.abs(B))),1e-30)/qmax
            A=np.clip(np.rint(A/sa),-qmax,qmax).astype(np.int64)
            B=np.clip(np.rint(B/sb),-qmax,qmax).astype(np.int64)
            scale=sa*sb;beats=K//lanes
        output=np.zeros((M,N),np.float32)
        coords=[(r,c) for r in range(0,M,4) for c in range(0,N,4)]
        chunk=max(1,min(256,65536//beats))
        if beats>65535:raise ValueError('Frame exceeds RTL limit')
        for base in range(0,len(coords),chunk):
            tiles=coords[base:base+chunk];gold={};seen=set()
            ap=self.work/'lhs.hex';bp=self.work/'rhs.hex'
            op=self.work/'offsets.hex';lp=self.work/'lengths.hex'
            with ap.open('w') as fa,bp.open('w') as fb:
                for t,(r,c) in enumerate(tiles):
                    if mode==2:
                        for pair in range(8):
                            for z in range(0,K,2):
                                wa=wb=0;ref=[]
                                for lane in range(2):
                                    p=2*pair+lane;rr=r+p//4;cc=c+p%4
                                    for d in range(2):
                                        wa|=int(A[rr,z+d])<<(lane*32+d*16)
                                        wb|=int(B[z+d,cc])<<(lane*32+d*16)
                                    ref.append(np.float32(AF[rr,z]*BF[z,cc]+AF[rr,z+1]*BF[z+1,cc]))
                                gold[t,pair*(K//2)+z//2]=ref
                                fa.write(f'{wa:032x}\n');fb.write(f'{wb:032x}\n')
                    else:
                        bits=4 if mode==0 else 8;mask=(1<<bits)-1
                        for z in range(0,K,lanes):
                            wa=wb=0
                            for i in range(4):
                                for d in range(lanes):
                                    wa|=(int(A[r+i,z+d]) & mask)<<(i*32+d*bits)
                                    wb|=(int(B[z+d,c+i]) & mask)<<(i*32+d*bits)
                            fa.write(f'{wa:032x}\n');fb.write(f'{wb:032x}\n')
                        gold[t,0]=A[r:r+4]@B[:,c:c+4]
            op.write_text(''.join(f'{t*beats:08x}\n' for t in range(len(tiles))))
            lp.write_text(f'{beats:08x}\n'*len(tiles))
            paths=[str(p.resolve()) for p in (ap,bp,op,lp)]
            if any(any(ch.isspace() for ch in p) for p in paths):raise ValueError('Whitespace path')
            self.send('G '+str(len(tiles))+' '+str(mode)+' '+' '.join(paths))
            expected=len(tiles)*(beats if mode==2 else 1)
            for _ in range(expected):
                v=self.line('EE_RESULT');t,j=int(v[1]),int(v[2]);s,carry=int(v[3],16),int(v[4],16)
                if (t,j) in seen or (t,j) not in gold:raise RuntimeError('Duplicate/unexpected result')
                seen.add((t,j));r,c=tiles[t]
                if mode==2:
                    if carry or s>>64:raise RuntimeError('BF16 result encoding')
                    got=np.frombuffer(struct.pack('<Q',s),dtype='<f4')
                    want=np.asarray(gold[t,j],np.float32)
                    # FP32 dot2 reference; explicitly permit four ULPs in this pilot oracle.
                    tol=4*np.abs(np.spacing(want))+np.float32(1e-30)
                    if not np.isfinite(got).all() or np.any(np.abs(got-want)>tol):
                        raise RuntimeError(f'BF16 kernel mismatch: {got} vs {want}')
                    pair=j//(K//2)
                    for lane in range(2):
                        p=pair*2+lane
                        output[r+p//4,c+p%4]=np.float32(output[r+p//4,c+p%4]+got[lane])
                    self.checked+=2
                else:
                    got=[]
                    for i in range(16):
                        x=((s>>(i*32))+(carry>>(i*32)))&0xffffffff
                        got.append(x-(1<<32) if x>>31 else x)
                    got=np.asarray(got,np.int64).reshape(4,4)
                    if not np.array_equal(got,gold[t,0]):raise RuntimeError('Integer RTL GEMM mismatch')
                    output[r:r+4,c:c+4]=got.astype(np.float32)*scale
                    self.checked+=16
            done=self.line('EE_DONE');self.tiles+=int(done[1]);self.cycles+=int(done[2]);self.last_cycle=int(done[3])
        return output[:m,:n]
