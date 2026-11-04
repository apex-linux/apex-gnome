// SPDX-License-Identifier: GPL-3.0-or-later
//
// G2's privacy indicators on real streams (G2_PRIVACY=1): direct.sh's run_case starts PipeWire
// before the shell, whose camera monitor connects only then, with a null source named g2-mic.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Scripting from 'resource:///org/gnome/shell/ui/scripting.js';
import * as Volume from 'resource:///org/gnome/shell/ui/status/volume.js';

Gio._promisify(Gio.Subprocess.prototype, 'wait_async');

const CAMERA_NODE = 'g2-camera';
const MIC_SOURCE = 'g2-mic';
const STREAM_WAIT_MS = 15000;
// Fedora ships no SPA videotestsrc, so GStreamer's provides the Camera node.
const CAMERA = ['gst-launch-1.0', '-q', 'videotestsrc', 'is-live=true', '!', 'video/x-raw,width=320,height=240,framerate=15/1', '!',
    'pipewiresink', 'mode=provide', `stream-properties=props,media.class=Video/Source,media.role=Camera,node.name=${CAMERA_NODE}`];
// Without a media type the stream is Stream/Input/Unknown, which WirePlumber links to nothing.
const VIEWER = ['gst-launch-1.0', '-q', 'pipewiresrc', `target-object=${CAMERA_NODE}`,
    'stream-properties=props,media.type=Video,media.category=Capture', '!', 'fakesink', 'sync=false'];
const RECORDER = ['gst-launch-1.0', '-q', 'pulsesrc', `device=${MIC_SOURCE}`, '!', 'fakesink', 'sync=false'];

function round(v) {
    return Math.round(v * 100) / 100;
}

function hex(c) {
    return `#${[c.red, c.green, c.blue, c.alpha].map(v => v.toString(16).padStart(2, '0')).join('')}`;
}

function boxOf(actor, unit) {
    const [x, y] = actor.get_transformed_position();
    const [width, height] = actor.get_transformed_size();
    return {x: round(x / unit.length), y: round(y / unit.length), width: round(width / unit.length), height: round(height / unit.length)};
}

function spawn(argv, log) {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.STDOUT_SILENCE});
    // The shell's still wall clock would time out PipeWire's waits in the clients at once.
    launcher.unsetenv('LD_PRELOAD');
    launcher.set_stderr_file_path(log);
    return launcher.spawnv(argv);
}

async function stop(proc) {
    proc.send_signal(15);
    await proc.wait_async(null).catch(() => false);
}

async function until(condition, timeoutMs = STREAM_WAIT_MS) {
    for (let waited = 0; waited < timeoutMs && !condition(); waited += 100)
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
    return condition();
}

function indicators() {
    const {_camera: camera, _volumeInput: input} = Main.panel.statusArea.quickSettings;
    return {camera: camera._indicator, microphone: input._indicator};
}

function groupReport(unit) {
    const pill = Main.panel.statusArea.quickSettings.get_first_child();
    const group = pill.get_children().find(a => a.name === 'apexPrivacyGroup') ?? null;
    const node = group?.get_theme_node();
    const glyphs = (group?.get_children() ?? []).filter(i => i.visible)
        .flatMap(indicator => indicator.get_children().filter(icon => icon.visible));
    const next = pill.get_children().find(a => a !== group && a.visible);
    return {
        pill: {...boxOf(pill, unit), paddingLeft: round(pill.get_theme_node().get_padding(St.Side.LEFT) / unit.length)},
        privacy: group?.visible ? {
            ...boxOf(group, unit), radius: round(node.get_border_radius(St.Corner.TOPLEFT) / unit.length),
            colour: hex(node.get_background_color()), next: boxOf(next, unit),
            glyphs: glyphs.map(g => ({...boxOf(g, unit), iconName: g.icon_name, colour: hex(g.get_theme_node().get_foreground_color())})),
        } : null,
    };
}

// The microphone's stream as volume.js reads it for the icon.
function micStream() {
    const control = Volume.getMixerControl();
    const source = control.get_default_source();
    return source ? {name: source.name, volume: source.volume, muted: source.is_muted, normal: control.get_vol_max_norm()} : null;
}

function logFile(client) {
    return GLib.build_filenamev([GLib.getenv('G2_CAPTURES'), `${GLib.getenv('G2_CASE')}-${client}.log`]);
}

// A viewer started before the camera's node is published finds no target and exits: start it again.
async function view(cameraShown) {
    const viewer = {proc: spawn(VIEWER, logFile('viewer')), starts: 1};
    for (let waited = 0; waited < STREAM_WAIT_MS && !cameraShown(); waited += 100) {
        if (viewer.proc.get_identifier() === null) {
            viewer.proc = spawn(VIEWER, logFile('viewer'));
            viewer.starts++;
        }
        // eslint-disable-next-line no-await-in-loop
        await Scripting.sleep(100);
    }
    return viewer;
}

export async function privacyReport({cssUnit, settle}) {
    const unit = cssUnit();
    Main.overview.hide();
    await settle();
    const shown = () => Object.values(indicators()).every(i => i.visible);
    const hidden = () => Object.values(indicators()).every(i => !i.visible);
    const report = {unit, before: {camera: indicators().camera.visible, microphone: indicators().microphone.visible}};
    const camera = spawn(CAMERA, logFile('camera'));
    const streams = [spawn(RECORDER, logFile('recorder'))];
    try {
        const viewer = await view(() => indicators().camera.visible);
        streams.push(viewer.proc);
        report.viewerStarts = viewer.starts;
        report.shown = await until(shown);
        await settle();
        report.inUse = {...groupReport(unit), microphone: indicators().microphone.icon_name, stream: micStream()};
        for (const proc of streams.splice(0))
            // eslint-disable-next-line no-await-in-loop
            await stop(proc);
        report.hidden = await until(hidden);
        await settle();
        report.after = groupReport(unit);
    } finally {
        await Promise.all([...streams, camera].map(stop));
    }
    return report;
}
