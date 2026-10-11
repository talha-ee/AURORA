# AURORA
### Adaptive Runtime Architecture for Edge Learning

**Architecture designed by Talha Alam**

AURORA is a mixed-precision edge-AI accelerator research prototype.
It combines runtime adaptation policies, tile scheduling, registered
command buffers, and four compute groups supporting INT4, INT8 and BF16.

The project explores how compute precision, group allocation and
learning activity can adapt to changing resource budgets. This repository
preserves the final RTL, mapped netlists, timing checkpoint, workload
runner code and saved validation results.

## Architecture

```mermaid
flowchart TD
    B["Budget and feedback"] --> G["Runtime governor"]
    G --> C["Safe configuration"]
    C --> S["Scheduler and dispatcher"]
    S --> Q["Four registered command buffers"]
    Q --> F["Four mixed-precision compute groups"]
    H["Host workload and adaptation"] --> D["Operand streams"]
    D --> F
    F --> O["Results and completion"]
    O --> H
    G --> A["Rank, scope, interval and training enable"]
    A --> H
Each compute group contains an INT4 4×4 mesh, an INT8 4×4 mesh,
and BF16 SIMD2 with two DOT2 lanes. Integer engines produce carry-save
sum/carry results; BF16 arithmetic produces FP32 partial results.
Streaming interfaces support readiness, backpressure and completion.
The BF16 path includes credit-managed buffering.
The governor selects precision and group allocation, together with
adaptation rank, scope, update interval and training enablement.
Configuration and command logic coordinate execution.
Runtime adaptation and training
Forward and classifier-gradient matrix operations execute in RTL.
Activations, loss, adapter assembly and optimizer updates are host
assisted. The demonstrated workload uses a frozen encoder with classifier
adapters; it does not establish autonomous full-network on-chip training.
The following policies were exercised using an emulated budget of 1024:
Usage	Precision	Group mask	Rank	Interval	Scope	Training
0	BF16	15	8	1	8	Enabled
650	INT8	7	4	2	4	Enabled
890	INT4	3	2	4	2	Enabled
1024	INT4	1	1	16	1	Disabled


Masks select compute groups. These tests demonstrate policy behavior,
not measured energy use or a physical sensor feedback loop.
Validation results
Full-system numerical integration passed six jobs and 4,508 checked
results, including 12 INT4 tiles, 12 INT8 tiles, 25 BF16 tiles and
837 BF16 credit-stall cycles.
The real-model smoke test used
dacorvo/mnist-mlp,
with four training images and four separate held-out images.
Evaluation	Images	Accuracy	Loss
Training before updates	4	75%	0.733589
Training after updates	4	75%	0.729053
Held-out test	4	100%	Approximately 0


Held-out predictions matched labels [4, 0, 5, 6].
Two host-assisted adapter updates exercised different policies.
The training-disabled case skipped updates. A separate BF16
real-activation kernel also passed.
Four-image accuracy is a smoke-test result, not a representative
MNIST benchmark. BF16 kernel validation does not establish
full-model BF16 accuracy.
Performance and mapped implementation
Metric	Result
Mapped cells	524,715
SKY130 mapped cell area	6.308714 mm²
Operating period	4.952000 ns
Operating frequency	201.938611 MHz
INT8 four-image forward cycles	7,061
Four-image batch latency	34.966072 µs
Amortized time per image	8.741518 µs
Derived accelerator throughput	114,396.6 images/s
Useful arithmetic throughput	61.4996 GOPS


Timing uses SKY130 HD at TT, 1.8 V and 25°C. The final mapped
checkpoint meets its operating period with margin.
Latency and throughput are derived from RTL cycles at the selected
mapped clock. They include testbench job guards and output stalls,
but exclude host and DMA time. They are not silicon measurements.
Mapped cell area is distinct from placed core or die area.
Physical implementation, routed timing, GDSII and workload power/energy
evaluation remain pending. Ultra-low-power operation has not yet been
demonstrated. The operating frequency is not a post-route Fmax.
Repository structure
Path	Contents
rtl/control/	Configuration, scheduling and command delivery
rtl/governor/	Runtime adaptation governor
rtl/engines/	Integer and floating-point compute engines
rtl/top/	Integrated system tops
release/aurora_final/	Netlist archives, source list and checksums
synth/ref_runtime_compute_system_mapped/checks/	Closure records, constraints and required candidate RTL
tests/workloads/hf_mnist_runtime/	Workload bridge, runner code, results and adapters
CITATION.cff	GitHub citation metadata
CITATION.bib	BibTeX citation


There are 28 active RTL sources. The compute-group stream wrapper
under the synthesis checks directory is a required final source.
Getting started
git clone https://github.com/talha-ee/AURORA.git
cd AURORA
mkdir -p build
iverilog -g2012 -s ee_runtime_compute_system -o build/aurora.vvp -c release/aurora_final/rtl_sources.f

This compiles the integrated top; it does not run the numerical workload.
Extract the final mapped netlists with:
gzip -dk release/aurora_final/mapped.v.gz
gzip -dk release/aurora_final/sta_compatible.v.gz

final_build.json records source hashes and uncompressed netlist hashes.
The archives preserve the original mapped netlist bytes.
The flow uses Icarus Verilog/VVP, Python and workload dependencies,
Yosys, OpenSTA and the matching SKY130 libraries. PDK libraries and
cached model/data assets are external dependencies. Historical manifests
and timing scripts retain original VM paths; configure those paths
before running on another machine.
Some retained filenames contain 500mhz; the final manifest's operating
period is authoritative. A different PDK requires remapping and fresh
timing and physical validation.
Citation
If you use this architecture, RTL or validation material, cite:
Alam, T. (2026). AURORA: Adaptive Runtime Architecture for Edge Learning
[RTL research prototype]. GitHub. https://github.com/talha-ee/AURORA

Record the commit SHA used in your experiments. GitHub's
Cite this repository feature reads CITATION.cff.
@misc{alam2026aurora,
  author = {Alam, Talha},
  title = {{AURORA}: Adaptive Runtime Architecture for Edge Learning},
  year = {2026},
  howpublished = {GitHub repository},
  url = {https://github.com/talha-ee/AURORA},
  note = {RTL research prototype}
}

Designer
Talha Alam — RTL and ASIC architecture design.
