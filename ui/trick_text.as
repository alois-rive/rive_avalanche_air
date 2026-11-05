// The strings the HUD and the screens show, composed from the pins (a pin
// carries a number only: docs/RIVE.md, section 4), written to the Ui view
// model (Game/ui) only when an input changes:
//
//   trickText    the banner's name from trickSpin .. trickGrind (lines.as)
//   trickPts     "+1,050" from trickPoints
//   praiseText   the praise word from `praise`
//   comboText    "2,450 x 3" from comboSum and comboMult
//   captionText  the announcer's line from captionLine (lines.as's table;
//                100 and up: the trick's name)
//   hs<i>Name, hs<i>Pts, hs<i>Grade, hs<i>Line   the table's rows from
//                hs<i>Score and hs<i>Tag (game_state.as packTag)
//   totalText, bestText, airText     the results' formatted numbers
//   schemeName   the title's scheme picker
//   balX, balY   the balance meter's place on the 320 x 240 grid, under the
//                rider (riderX, riderY are the Scene3D's points)
//
// It also ticks the initials entry (ui_state.as). A Node on Main that draws
// nothing.

import { Node, Context } from "rive/host";
import { ViewModel } from "rive/data";
import {
    CAPTION_LINES, CAPTION_TRICK, GRADE_LETTERS, PRAISE_WORDS, SCHEME_NAMES, commas, initialsText, oneDecimal,
    trickName,
} from "./lines";
import { BoolProp, NumberProp, StringProp, bindUi, bool_, initialsTick, num, str, ui } from "./ui_state";

const TABLE: i32 = 10;

class Row {
    score: NumberProp;
    tag: NumberProp;
    name: StringProp;
    pts: StringProp;
    grade: StringProp;
    line: StringProp;
    lastScore: f64 = -1;
    lastTag: f64 = -1;

    constructor(d: ViewModel?, u: ViewModel?, i: i32) {
        this.score = num(d, "hs" + i.toString() + "Score");
        this.tag = num(d, "hs" + i.toString() + "Tag");
        this.name = str(u, "hs" + i.toString() + "Name");
        this.pts = str(u, "hs" + i.toString() + "Pts");
        this.grade = str(u, "hs" + i.toString() + "Grade");
        this.line = str(u, "hs" + i.toString() + "Line");
    }

    update(): void {
        const s = this.score.v;
        const t = this.tag.v;
        if (s == this.lastScore && t == this.lastTag) return;
        this.lastScore = s;
        this.lastTag = t;
        const tag = <i32>Math.round(t);
        const initials = tag >> 3;
        const grade = (tag & 7) >> 1;
        const line = tag & 1;
        this.name.set(initials > 0 ? initialsText(initials) : "---");
        this.pts.set(commas(s));
        this.grade.set(GRADE_LETTERS[grade & 3]);
        this.line.set(line == 1 ? "H" : "L");
    }
}

export class TrickText extends Node {
    ready: bool = false;
    // inputs
    spin: NumberProp = new NumberProp();
    dir: NumberProp = new NumberProp();
    flip: NumberProp = new NumberProp();
    grab1: NumberProp = new NumberProp();
    grab2: NumberProp = new NumberProp();
    sw: BoolProp = new BoolProp();
    grind: NumberProp = new NumberProp();
    points: NumberProp = new NumberProp();
    praise: NumberProp = new NumberProp();
    comboSum: NumberProp = new NumberProp();
    comboMult: NumberProp = new NumberProp();
    captionLine: NumberProp = new NumberProp();
    captionSeq: NumberProp = new NumberProp();
    resTotal: NumberProp = new NumberProp();
    resBest: NumberProp = new NumberProp();
    resAir: NumberProp = new NumberProp();
    scheme: NumberProp = new NumberProp();
    riderX: NumberProp = new NumberProp();
    riderY: NumberProp = new NumberProp();
    scale: NumberProp = new NumberProp();
    gx: NumberProp = new NumberProp();
    gy: NumberProp = new NumberProp();
    // outputs
    trickText: StringProp = new StringProp();
    trickPts: StringProp = new StringProp();
    praiseText: StringProp = new StringProp();
    comboText: StringProp = new StringProp();
    captionText: StringProp = new StringProp();
    totalText: StringProp = new StringProp();
    bestText: StringProp = new StringProp();
    airText: StringProp = new StringProp();
    schemeName: StringProp = new StringProp();
    balX: NumberProp = new NumberProp();
    balY: NumberProp = new NumberProp();
    rows: Array<Row> = [];
    // the last inputs, to compose only on a change
    trickKey: f64 = -1;
    lastPoints: f64 = -1;
    lastPraise: f64 = -1;
    lastComboSum: f64 = -1;
    lastComboMult: f64 = -1;
    lastCaption: f64 = -2;
    lastCaptionSeq: f64 = -1;
    lastTotal: f64 = -1;
    lastBest: f64 = -1;
    lastAir: f64 = -1;
    lastScheme: f64 = -1;

    override init(context: Context): bool {
        const game = context.viewModel();
        bindUi(game);
        if (!ui.bound) return true;
        const d = ui.data;
        const u = ui.view;
        this.spin = num(d, "trickSpin");
        this.dir = num(d, "trickDir");
        this.flip = num(d, "trickFlip");
        this.grab1 = num(d, "trickGrab1");
        this.grab2 = num(d, "trickGrab2");
        this.sw = bool_(d, "trickSwitch");
        this.grind = num(d, "trickGrind");
        this.points = num(d, "trickPoints");
        this.praise = num(d, "praise");
        this.comboSum = num(d, "comboSum");
        this.comboMult = num(d, "comboMult");
        this.captionLine = num(d, "captionLine");
        this.captionSeq = num(d, "captionSeq");
        this.resTotal = num(d, "resTotal");
        this.resBest = num(d, "resBestCombo");
        this.resAir = num(d, "resLongestAir");
        this.scheme = num(d, "scheme");
        this.riderX = num(d, "riderX");
        this.riderY = num(d, "riderY");
        this.scale = num(u, "scale");
        this.gx = num(u, "gx");
        this.gy = num(u, "gy");
        this.trickText = str(u, "trickText");
        this.trickPts = str(u, "trickPts");
        this.praiseText = str(u, "praiseText");
        this.comboText = str(u, "comboText");
        this.captionText = str(u, "captionText");
        this.totalText = str(u, "totalText");
        this.bestText = str(u, "bestText");
        this.airText = str(u, "airText");
        this.schemeName = str(u, "schemeName");
        this.balX = num(u, "balX");
        this.balY = num(u, "balY");
        for (let i = 1; i <= TABLE; i++) this.rows.push(new Row(d, u, i));
        this.ready = true;
        this.compose();
        return true;
    }

    override advance(seconds: f64): bool {
        if (!this.ready) return true;
        this.compose();
        initialsTick();
        return true;
    }

    compose(): void {
        // the trick's name: a key of every input, so it is rebuilt on a change only
        const key = this.spin.v + 2000 * (this.dir.v + 4 * (this.flip.v + 8 * (this.grab1.v + 8 * (this.grab2.v
            + 8 * (this.grind.v + 64 * (this.sw.v ? 1 : 0))))));
        let trickChanged = false;
        if (key != this.trickKey) {
            this.trickKey = key;
            trickChanged = true;
            this.trickText.set(trickName(<i32>this.spin.v, <i32>this.dir.v, <i32>this.flip.v, <i32>this.grab1.v,
                                         <i32>this.grab2.v, this.sw.v, <i32>this.grind.v));
        }
        const pts = this.points.v;
        if (pts != this.lastPoints) {
            this.lastPoints = pts;
            this.trickPts.set("+" + commas(pts));
        }
        const pr = this.praise.v;
        if (pr != this.lastPraise) {
            this.lastPraise = pr;
            const i = <i32>pr;
            this.praiseText.set(i >= 0 && i < PRAISE_WORDS.length ? PRAISE_WORDS[i] : "");
        }
        const cs = this.comboSum.v;
        const cm = this.comboMult.v;
        if (cs != this.lastComboSum || cm != this.lastComboMult) {
            this.lastComboSum = cs;
            this.lastComboMult = cm;
            this.comboText.set(commas(cs) + " x " + (<i32>cm).toString());
        }
        const cl = this.captionLine.v;
        const cq = this.captionSeq.v;
        if (cl != this.lastCaption || cq != this.lastCaptionSeq || (trickChanged && cl >= <f64>CAPTION_TRICK)) {
            this.lastCaption = cl;
            this.lastCaptionSeq = cq;
            const line = <i32>cl;
            if (line >= CAPTION_TRICK) {
                this.captionText.set(this.trickTextNow());
            } else if (line >= 0 && line < CAPTION_LINES.length) {
                this.captionText.set(CAPTION_LINES[line]);
            } else {
                this.captionText.set("");
            }
        }
        const tot = this.resTotal.v;
        if (tot != this.lastTotal) {
            this.lastTotal = tot;
            this.totalText.set(commas(tot));
        }
        const best = this.resBest.v;
        if (best != this.lastBest) {
            this.lastBest = best;
            this.bestText.set(commas(best));
        }
        const air = this.resAir.v;
        if (air != this.lastAir) {
            this.lastAir = air;
            this.airText.set(oneDecimal(air) + "S");
        }
        const sc = this.scheme.v;
        if (sc != this.lastScheme) {
            this.lastScheme = sc;
            const i = <i32>sc;
            this.schemeName.set(i >= 0 && i < 3 ? SCHEME_NAMES[i] : SCHEME_NAMES[0]);
        }
        for (let i = 0; i < this.rows.length; i++) this.rows[i].update();
        // the balance meter under the rider, in grid pixels (whole ones)
        // (no screen position yet, 0 and 0: under the grid's centre)
        const s = this.scale.v > 0 ? this.scale.v : 1;
        const rx = this.riderX.v;
        const ry = this.riderY.v;
        let bx = rx == 0 && ry == 0 ? 160 : Math.round((rx - this.gx.v) / s);
        let by = rx == 0 && ry == 0 ? 150 : Math.round((ry - this.gy.v) / s) + 20;
        if (bx < 32) bx = 32;
        if (bx > 288) bx = 288;
        if (by < 64) by = 64;
        if (by > 200) by = 200;
        this.balX.set(bx);
        this.balY.set(by);
    }

    trickTextNow(): string {
        return trickName(<i32>this.spin.v, <i32>this.dir.v, <i32>this.flip.v, <i32>this.grab1.v, <i32>this.grab2.v,
                         this.sw.v, <i32>this.grind.v);
    }
}
