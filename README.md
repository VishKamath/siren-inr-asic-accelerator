# ASIC-Oriented SIREN Hardware Accelerator & Arbitrary-Scale Image Upscaler

A synthesizable, pipelined SystemVerilog hardware accelerator for Implicit Neural Representation (INR) decoding and continuous-domain super-resolution using a 2-layer Sinusoidal Representation Network (SIREN).

---

## 1. Overview

Conventional digital image decoders rely on discrete pixel matrices stored in frame buffers, requiring bilinear, bicubic, or CNN-based interpolation to upscale. 

In contrast, this hardware accelerator models visual signals as a continuous coordinate mapping function:

$$f_\theta(x, y) \rightarrow \text{Pixel Intensity}$$

Because $(x, y) \in [-1.0, 1.0]$ are fed as continuous coordinate values rather than discrete array indices, the architecture functions as a native **arbitrary-scale image upscaler**. You can generate higher resolution outputs ($2\times$, $4\times$, $8\times$) simply by sampling the coordinate space at a finer fixed-point step size $\Delta$ without altering the hardware datapath or inserting interpolation memory buffers.

---

## 2. Key Architectural Features

* **Parallel 16-Neuron Hidden Layer:** Implemented via SystemVerilog `generate` blocks to evaluate 16 parallel dot products simultaneously per clock cycle.
* **16-Stage Pipelined CORDIC Engine:** Evaluates continuous trigonometric activations ($\sin(\cdot)$ / $\cos(\cdot)$) on-the-fly in vector-rotation mode, completely eliminating SRAM lookup tables.
* **Gain Factor Calibration:** Pre-scales initial coordinate seeds with $1/K \approx 0.607252935$ to neutralize the CORDIC vector growth factor ($K \approx 1.64676$).
* **Quadrant Phase Folder:** Normalizes unbounded angular inputs from $[-30\pi, +30\pi]$ into the CORDIC convergence zone of $[-\pi, \pi]$ using modulo arithmetic.
* **Q4.12 Fixed-Point Datapath:** Arithmetic datapath optimized for fixed-point DSP/ASIC targets with signed right-shifts (`>>> 12`) to preserve dynamic range.
* **Layer 2 Reduction Tree & Saturation:** Multi-channel accumulation logic with extended guard bits to avoid overflow roll-over, clipping cleanly to `16'sh7FFF` ($+7.999$) and `16'sh8000` ($-8.000$).

---

## 3. Hardware Datapath
