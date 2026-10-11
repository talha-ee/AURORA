from pathlib import Path
import hashlib,json,re,shutil,subprocess,time,resource
import numpy as np
root=Path('tests/workloads/hf_mnist_runtime')
work=Path(json.loads((root/'current_run.json').read_text())['work'])
def sha(p):
    h = hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda: f.read(1048576), b''):
            h.update(b)
    return h.hexdigest()

checks = Path('synth/ref_runtime_compute_system_mapped/checks')
closed_path = checks/'runtime_compute_system_final_closed.json'
closed = json.loads(closed_path.read_text())
if not closed.get('mapped_timing_closed'):
    raise SystemExit('Closed design checkpoint required.')
parents = list(Path(closed['netlist']).parents)
candidates = [p for p in parents if p.name.startswith('control_candidate_')]
mappings = [p for p in parents if p.name.startswith('mapping_')]
if len(candidates) != 1 or len(mappings) != 1:
    raise SystemExit('Cannot identify the RTL used by the closed design.')
control_path = candidates[0]/'control_candidate_manifest.json'
mapping_path = mappings[0]/'wrapper_mapping_manifest.json'
join_path = Path(closed['netlist']).parent.parent.parent/'stream_join_manifest.json'
join = json.loads(join_path.read_text())
expected = join['protected_input_hashes'].get(str(mapping_path))
if not expected or sha(mapping_path) != expected:
    raise SystemExit('Closed mapping provenance mismatch.')
mapping = json.loads(mapping_path.read_text())
control = json.loads(control_path.read_text())
reg_path = Path(mapping['numeric_regression_manifest'])
if sha(reg_path) != mapping['numeric_regression_manifest_sha256']:
    raise SystemExit('Validated regression manifest changed.')
reg = json.loads(reg_path.read_text())
if not reg.get('full_numeric_regression_passed'):
    raise SystemExit('Passing numerical regression required.')
tb = Path(reg['testbench'])
if sha(tb) != reg['testbench_sha256']:
    raise SystemExit('Validated testbench changed.')
sources = [str(p) for p in reg['compile_command']
           if str(p).endswith(('.sv', '.v')) and str(p) != str(tb)]
if len(sources) != len(set(sources)) or not sources:
    raise SystemExit('Unexpected validated source list.')
protected = dict(mapping['protected_input_hashes'])
protected.update(join['protected_input_hashes'])
protected.update({str(closed_path): sha(closed_path), str(reg_path): sha(reg_path),
                  str(control_path): sha(control_path), str(tb): sha(tb)})
active = {}
for p in sources:
    expected = protected.get(p)
    if not expected or sha(p) != expected:
        raise SystemExit('Active RTL provenance mismatch: '+p)
    active[p] = expected
if control['candidate_rtl'] not in sources:
    raise SystemExit('The closed design control candidate is absent.')

print('CURRENT RTL PROVENANCE PASS:',len(sources),'sources.',flush=True)
body=(Path(__file__).parent/'hf_rtl_server_body.sv').read_text()
text=tb.read_text()
match=re.search(r'\bee_runtime_compute_system\s+dut\s*\(',text)
if not match:raise SystemExit('Validated top-level instance missing.')
level=1;i=match.end()
while i<len(text) and level:
    if text[i]=='(':level+=1
    elif text[i]==')':level-=1
    i+=1
while i<len(text) and text[i].isspace():i+=1
if level or text[i]!=';':raise SystemExit('Validated testbench header parse failed.')
server=work/'rtl_server.sv';server.write_text(text[:i+1]+'\n'+body)
binary=work/'rtl_server.out';cmd=list(reg['compile_command'])
cmd[0]=shutil.which('iverilog') or 'iverilog'
cmd[cmd.index('-o')+1]=str(binary)
cmd=[str(server) if str(p)==str(tb) else str(p) for p in cmd]
log=work/'compile.log'
def limited():
    resource.setrlimit(resource.RLIMIT_AS,(2*1024**3,2*1024**3))
print('Compiling the full runtime + four compute groups; 2 GiB child limit.',flush=True)
with log.open('w') as out:
    child=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT,preexec_fn=limited)
    while True:
        try:status=child.wait(timeout=15);break
        except subprocess.TimeoutExpired:print('Full RTL compile running.',flush=True)
if status:
    print(''.join(log.read_text().splitlines(keepends=True)[-20:]),flush=True)
    raise SystemExit('Compile failed; original RTL retained.')
info=dict(active_sources=sources,active_source_hashes=active,
    closed_manifest=str(closed_path),closed_manifest_sha256=sha(closed_path),
    period_ns=closed.get('clock_period_ns'),testbench=str(server),
    testbench_sha256=sha(server),binary=str(binary),binary_sha256=sha(binary),
    compile_command=cmd,backend_sha256=sha(Path(__file__).parent/'hf_rtl_backend.py'))
(work/'rtl_manifest.json').write_text(json.dumps(info,indent=2)+'\n')
print('FULL RTL WORKLOAD BRIDGE COMPILED:',binary,flush=True)
