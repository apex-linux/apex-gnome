// SPDX-License-Identifier: GPL-3.0-or-later
//
// PNG through GLib's zlib, not GdkPixbuf: GdkPixbuf may hand decoding to a sandboxed
// loader, which a container cannot start.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
const CHANNELS_BY_COLOR_TYPE = new Map([[2, 3], [6, 4]]);
const COLOR_TYPE_RGBA = 6;
const READ_CHUNK = 1 << 20;

export const Filter = Object.freeze({NONE: 0, SUB: 1, UP: 2, AVERAGE: 3, PAETH: 4});

const CRC_TABLE = (() => {
    const table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++)
            c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        table[n] = c >>> 0;
    }
    return table;
})();

function crc32(bytes) {
    let c = 0xffffffff;
    for (const b of bytes)
        c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}

function readU32(bytes, at) {
    return ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0;
}

function writeU32(bytes, at, value) {
    bytes[at] = value >>> 24;
    bytes[at + 1] = (value >>> 16) & 0xff;
    bytes[at + 2] = (value >>> 8) & 0xff;
    bytes[at + 3] = value & 0xff;
}

function concat(parts) {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const p of parts) {
        out.set(p, at);
        at += p.length;
    }
    return out;
}

function convert(bytes, converter) {
    const stream = new Gio.ConverterInputStream({
        base_stream: Gio.MemoryInputStream.new_from_bytes(new GLib.Bytes(bytes)),
        converter,
    });
    const parts = [];
    for (;;) {
        const block = stream.read_bytes(READ_CHUNK, null);
        if (block.get_size() === 0)
            break;
        parts.push(block.toArray());
    }
    stream.close(null);
    return concat(parts);
}

function paeth(left, up, upLeft) {
    const p = left + up - upLeft;
    const toLeft = Math.abs(p - left);
    const toUp = Math.abs(p - up);
    const toUpLeft = Math.abs(p - upLeft);
    if (toLeft <= toUp && toLeft <= toUpLeft)
        return left;
    return toUp <= toUpLeft ? up : upLeft;
}

function predict(filter, row, prev, i, bpp) {
    const left = i >= bpp ? row[i - bpp] : 0;
    const up = prev[i];
    switch (filter) {
    case Filter.NONE:
        return 0;
    case Filter.SUB:
        return left;
    case Filter.UP:
        return up;
    case Filter.AVERAGE:
        return (left + up) >>> 1;
    case Filter.PAETH:
        return paeth(left, up, i >= bpp ? prev[i - bpp] : 0);
    default:
        throw new Error(`unknown PNG filter type ${filter}`);
    }
}

/**
 * @param {Uint8Array} bytes
 * @returns {{width: number, height: number}}
 */
export function size(bytes) {
    if (bytes.length < 24 || SIGNATURE.some((b, i) => bytes[i] !== b))
        throw new Error('not a PNG file');
    return {width: readU32(bytes, 16), height: readU32(bytes, 20)};
}

/**
 * @param {Uint8Array} bytes
 * @returns {{width: number, height: number, rgba: Uint8Array}}
 */
export function decode(bytes) {
    const {width, height} = size(bytes);
    let header = null;
    const idat = [];
    for (let at = SIGNATURE.length; at + 8 <= bytes.length;) {
        const length = readU32(bytes, at);
        const type = String.fromCharCode(...bytes.subarray(at + 4, at + 8));
        const data = bytes.subarray(at + 8, at + 8 + length);
        if (type === 'IHDR')
            header = {depth: data[8], colorType: data[9], interlace: data[12]};
        else if (type === 'IDAT')
            idat.push(data);
        else if (type === 'IEND')
            break;
        at += 12 + length;
    }
    const channels = CHANNELS_BY_COLOR_TYPE.get(header?.colorType);
    if (!header || header.depth !== 8 || !channels || header.interlace !== 0) {
        throw new Error(`unsupported PNG (bit depth ${header?.depth}, colour type ` +
            `${header?.colorType}, interlace ${header?.interlace}): 8-bit RGB or RGBA only`);
    }
    const stride = width * channels;
    const raw = convert(concat(idat),
        new Gio.ZlibDecompressor({format: Gio.ZlibCompressorFormat.ZLIB}));
    if (raw.length !== height * (stride + 1))
        throw new Error(`PNG data is ${raw.length} bytes, expected ${height * (stride + 1)}`);

    const rgba = new Uint8Array(width * height * 4);
    let prev = new Uint8Array(stride);
    let row = new Uint8Array(stride);
    for (let y = 0; y < height; y++) {
        const at = y * (stride + 1);
        const filter = raw[at];
        for (let i = 0; i < stride; i++)
            row[i] = (raw[at + 1 + i] + predict(filter, row, prev, i, channels)) & 0xff;
        for (let x = 0; x < width; x++) {
            const from = x * channels;
            const to = (y * width + x) * 4;
            rgba[to] = row[from];
            rgba[to + 1] = row[from + 1];
            rgba[to + 2] = row[from + 2];
            rgba[to + 3] = channels === 4 ? row[from + 3] : 255;
        }
        [prev, row] = [row, prev];
    }
    return {width, height, rgba};
}

function chunk(type, data) {
    const out = new Uint8Array(12 + data.length);
    writeU32(out, 0, data.length);
    for (let i = 0; i < 4; i++)
        out[4 + i] = type.charCodeAt(i);
    out.set(data, 8);
    writeU32(out, 8 + data.length, crc32(out.subarray(4, 8 + data.length)));
    return out;
}

/**
 * @param {{width: number, height: number, rgba: Uint8Array}} image
 * @param {(y: number) => number} [filterOfRow]
 * @returns {Uint8Array}
 */
export function encode({width, height, rgba}, filterOfRow = () => Filter.NONE) {
    const stride = width * 4;
    const raw = new Uint8Array(height * (stride + 1));
    const none = new Uint8Array(stride);
    for (let y = 0; y < height; y++) {
        const row = rgba.subarray(y * stride, (y + 1) * stride);
        const prev = y > 0 ? rgba.subarray((y - 1) * stride, y * stride) : none;
        const filter = filterOfRow(y);
        const at = y * (stride + 1);
        raw[at] = filter;
        for (let i = 0; i < stride; i++)
            raw[at + 1 + i] = (row[i] - predict(filter, row, prev, i, 4)) & 0xff;
    }
    const header = new Uint8Array(13);
    writeU32(header, 0, width);
    writeU32(header, 4, height);
    header.set([8, COLOR_TYPE_RGBA, 0, 0, 0], 8);
    const idat = convert(raw,
        new Gio.ZlibCompressor({format: Gio.ZlibCompressorFormat.ZLIB, level: 1}));
    return concat([Uint8Array.from(SIGNATURE), chunk('IHDR', header), chunk('IDAT', idat),
        chunk('IEND', new Uint8Array(0))]);
}
