# AURORA

Adaptive Runtime Architecture for Edge Learning.

**Architecture designed by Talha Alam.**

Four mixed-precision compute groups: INT4, INT8 and BF16.
Runtime precision and adaptation policy; host-assisted training.

Final RTL and SKY130 mapped timing checkpoint are included.
MNIST results are a four-image smoke test; performance is cycle-derived.
Physical implementation is pending. Workload power is not measured.

Final netlists: `release/aurora_final/*.v.gz`; extract using `gzip -dk`.
External PDK/model assets and original VM paths require local configuration.
