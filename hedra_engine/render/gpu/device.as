// The render device, on the Rive engine.
//
// A rive script does not enumerate adapters or request a device: the host
// owns the one GPU device and picks the backend, and there is no readback.
// What this module provides:
//
// - `AdapterSummary` (the `adapter` object of the render report), describing
//   the one "adapter" there is: `rive` on the host's backend (derived from the
//   shader target the host asks for), device type `other` (an adapter that
//   reports no type), no driver string.
// - `AdapterChoice.parse` and the `Gpu.create` choice logic, run against that
//   single adapter, so `--adapter` gives its usual error messages and hints.
// - `Gpu`: the host `Context`, its `GPUCanvas` and `GPUFeatures` (which
//   carry the device limits).
//
// There are no GPU-to-CPU copies: the finishing work of a view runs as GPU
// passes (renderer.as).

import { Context } from "rive/host";
import { GPUCanvas, GPUFeatures } from "rive/gpu";
import { abi } from "rive/bindings";
import { Result, toAsciiLowercase, trimUnicode } from "../../base/util";
import { RenderError } from "../errors";

export class AdapterSummary {
    name: string;
    backend: string;
    deviceType: string;
    driver: string;
    // Milestone 67: the GPU's maker as far as the host lets a script know
    // it (a rive script sees no adapter string): "Apple" on Metal, which
    // the rive host draws with on macOS and iOS (Apple silicon), else ""
    // (unknown). Read by the depth prepass's disable_for_vendors
    // (prepass.as); not part of `describe`, so no answer changes.
    vendor: string = "";

    constructor(name: string, backend: string, deviceType: string, driver: string) {
        this.name = name;
        this.backend = backend;
        this.deviceType = deviceType;
        this.driver = driver;
    }

    // A summary from adapter info: `driver` joined with `driverInfo`
    // and trimmed when the latter is not empty.
    static fromInfo(name: string, backend: string, deviceType: string, driver: string, driverInfo: string): AdapterSummary {
        return new AdapterSummary(
            name,
            backend,
            deviceType,
            driverInfo.length == 0 ? driver : trimUnicode(driver + " " + driverInfo),
        );
    }

    isSoftware(): bool {
        return this.deviceType == "cpu";
    }

    // One line for `--adapter list`.
    describe(): string {
        let s = this.name + " (" + this.backend + ", " + this.deviceType + ")";
        if (this.driver.length != 0) {
            s += " [" + this.driver + "]";
        }
        return s;
    }

    clone(): AdapterSummary {
        const c = new AdapterSummary(this.name, this.backend, this.deviceType, this.driver);
        c.vendor = this.vendor;
        return c;
    }

    equals(o: AdapterSummary): bool {
        return this.name == o.name && this.backend == o.backend && this.deviceType == o.deviceType && this.driver == o.driver;
    }
}

export enum AdapterChoiceKind {
    // The best GPU available, a software adapter if that is all there is.
    Default,
    // A CPU (software) adapter. rive has none, so this choice always fails;
    // `lavapipe`, `warp` and `llvmpipe` are accepted as other names for it.
    Software,
    // Case-insensitive substring of the adapter or backend name.
    Named,
}

export class AdapterChoice {
    kind: AdapterChoiceKind = AdapterChoiceKind.Default;
    // The needle of `Named`.
    name: string = "";

    constructor(kind: AdapterChoiceKind = AdapterChoiceKind.Default, name: string = "") {
        this.kind = kind;
        this.name = name;
    }

    static parse(s: string): AdapterChoice {
        const l = toAsciiLowercase(s);
        if (l == "" || l == "default" || l == "auto") {
            return new AdapterChoice(AdapterChoiceKind.Default);
        }
        if (l == "software" || l == "cpu" || l == "lavapipe" || l == "warp" || l == "llvmpipe" || l == "fallback") {
            return new AdapterChoice(AdapterChoiceKind.Software);
        }
        return new AdapterChoice(AdapterChoiceKind.Named, s);
    }

    clone(): AdapterChoice {
        return new AdapterChoice(this.kind, this.name);
    }

    equals(o: AdapterChoice): bool {
        return this.kind == o.kind && this.name == o.name;
    }
}

// The name of the backend the host renders with ("metal", "vulkan", ...),
// from the shader target it asks RSTB containers for (std/rive/gpu.as
// `bindingMapTargetFor`: 0 wgsl, 1 glsl, 2 msl, 3 hlsl, 5 spirv).
export function backendName(shaderTarget: u32): string {
    switch (shaderTarget) {
        case 0: return "webgpu";
        case 1: return "gl";
        case 2: return "metal";
        case 3: return "dx12";
        case 5: return "vulkan";
        default: return "unknown";
    }
}

// The one adapter a rive script sees.
export function hostAdapter(shaderTarget: u32): AdapterSummary {
    const a = AdapterSummary.fromInfo("rive", backendName(shaderTarget), "other", "", "");
    a.vendor = adapterVendor(a.backend);
    return a;
}

// Milestone 67: the vendor AdapterSummary.vendor names for a host drawing
// with `backend` (see there): the rive host draws with Metal only on
// Apple's systems, whose GPUs it targets; every other backend's maker is
// not known to a script.
export function adapterVendor(backend: string): string {
    return backend == "metal" ? "Apple" : "";
}

// Every adapter, best first: here only the host's.
export function listAdapters(): Array<AdapterSummary> {
    return [hostAdapter(abi.rive_gpu_shader_target())];
}

// The hint of every NoAdapter error: rive draws only on its host's GPU
// device (see the rive-cli README, "Status", for the verified hosts).
export const NO_ADAPTER_HINT = "rive renders only on the GPU device of its host and has no software adapter: on macOS it needs a Metal-capable GPU (the rive-cli backends for Linux and Windows are unverified). `render --adapter list` shows the adapter rive reports";

// The adapter `choice` selects from `adapters` (best first). Returns the
// index of the chosen adapter, or a NoAdapter error. Split out
// (and pure) so the choice logic is testable without a device.
export function chooseAdapter(adapters: Array<AdapterSummary>, choice: AdapterChoice): Result<i32> {
    const names = new Array<string>();
    for (let i = 0; i < adapters.length; i++) names.push(adapters[i].describe());
    let idx: i32 = -1;
    switch (choice.kind) {
        case AdapterChoiceKind.Default: {
            idx = adapters.length > 0 ? 0 : -1;
            break;
        }
        case AdapterChoiceKind.Software: {
            // A CPU adapter if listed; the host cannot be asked for a
            // fallback adapter, so there is none otherwise.
            for (let i = 0; i < adapters.length; i++) {
                if (adapters[i].deviceType == "cpu") {
                    idx = i;
                    break;
                }
            }
            break;
        }
        default: {
            const n = toAsciiLowercase(choice.name);
            for (let i = 0; i < adapters.length; i++) {
                const a = adapters[i];
                if (toAsciiLowercase(a.name).includes(n) || toAsciiLowercase(a.backend) == n) {
                    idx = i;
                    break;
                }
            }
            if (idx < 0) {
                return RenderError.noAdapter(
                    "no adapter matches '" + choice.name + "'",
                    names.length == 0 ? NO_ADAPTER_HINT : "available: " + names.join("; "),
                ).fail<i32>();
            }
            break;
        }
    }
    if (idx < 0) {
        return RenderError.noAdapter(
            choice.kind == AdapterChoiceKind.Software ? "no software adapter available" : "no graphics adapter available",
            NO_ADAPTER_HINT,
        ).fail<i32>();
    }
    return Result.okv<i32>(idx);
}

// The device a renderer draws with: the host context, its
// GPU canvas (the presentation target, resized per output) and features.
export class Gpu {
    ctx: Context;
    canvas: GPUCanvas;
    features: GPUFeatures;
    info: AdapterSummary;

    constructor(ctx: Context, canvas: GPUCanvas, features: GPUFeatures, info: AdapterSummary) {
        this.ctx = ctx;
        this.canvas = canvas;
        this.features = features;
        this.info = info;
    }

    // The host device, after checking `choice` against the one adapter.
    static create(ctx: Context, choice: AdapterChoice): Result<Gpu> {
        const adapters = listAdapters();
        const pick = chooseAdapter(adapters, choice);
        if (!pick.ok) return pick.forward<Gpu>();
        const info = adapters[pick.value];
        const canvas = ctx.gpuCanvas(1, 1);
        if (canvas == null) {
            return RenderError.device(info.name + " (" + info.backend + "): no GPU canvas (the host has no GPU device)").fail<Gpu>();
        }
        return Result.okv<Gpu>(new Gpu(ctx, canvas, ctx.features(), info));
    }

    // The largest render target side: `MAX_DIMENSION` in options.as, capped
    // by the device (4096 when the host does not say).
    maxTextureSize(): u32 {
        return this.features.known ? this.features.maxTextureSize2D : 4096;
    }
}
