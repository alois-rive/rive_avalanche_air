// What the driver (run.as) hands the cameras (camera.as) each frame: the
// rider as drawn (between the model's last two ticks), the camera wanted
// and the moments it cuts on. One module global, written by run.as before
// the Lens's script runs (the Run root is first in tree order).

export const CAM_CHASE: i32 = 0;     // on the snow, in the air, on a rail (blended inside)
export const CAM_CRASH: i32 = 1;     // holds where it was, watches the tumble
export const CAM_FINISH: i32 = 2;    // past the arch, low, facing the rider
export const CAM_TITLE: i32 = 3;     // the attract: cuts between angles round the rider
export const CAM_GATE: i32 = 4;      // the start gate, in front of the rider

export class View {
    mode: i32 = CAM_TITLE;
    // the next frame cuts (no spring): a respawn, a restart, a phase
    cut: bool = true;
    // the rider as drawn: the board's place and the travel's flat yaw
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    travel: f32 = 0;
    speed: f32 = 0;
    tuck: f32 = 0;
    inAir: bool = false;
    airTime: f32 = 0;
    grinding: bool = false;
    // the rail's flat direction of travel (on a rail)
    railYaw: f32 = 0;
    // the solved landing (in the air)
    landX: f32 = 0;
    landY: f32 = 0;
    landZ: f32 = 0;
    landT: f32 = 0;
    // the finish arch: its place on the line and its flat yaw
    finishX: f32 = 0;
    finishY: f32 = 0;
    finishZ: f32 = 0;
    finishYaw: f32 = 0;
    // seconds into the phase (the attract's cuts)
    phaseTime: f32 = 0;
    reducedMotion: bool = false;
}

export const view: View = new View();
