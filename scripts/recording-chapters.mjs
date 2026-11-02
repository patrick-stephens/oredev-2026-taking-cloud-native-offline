import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const chapterPattern = /^(?:[1-6] \/ [^\r\n]+|PHASE [1-4]: [^\r\n]+|CLEANUP: [^\r\n]+|EXPECTED FAILURE: [^\r\n]+|PASS: tampered image rejected[^\r\n]*|PROVED: [^\r\n]+|VERIFIED: package signature[^\r\n]+|INITIALIZED: [^\r\n]+|BEFORE \(packaged chart\): [^\r\n]+|PASS: no forbidden[^\r\n]+|RECORDING COMPLETE: [^\r\n]+)$/gm;

export function finalize(raw) {
    const [headerLine, ...lines] = raw.trimEnd().split('\n');
    const header = JSON.parse(headerLine);
    if (header.version !== 2) throw new Error('Expected an asciicast v2 recording.');
    // Ignore any user-level playback idle limit; the cast and MP4 share real time.
    delete header.idle_time_limit;
    const events = lines.map(line => JSON.parse(line));
    if (!events.length) throw new Error('Recording has no events.');
    const output = [];
    const chapters = [];
    let pending = '';
    let previousTime = 0;
    let lastVisualTime = 0;
    let lastMarker;
    for (const event of events) {
        const [time, type, data] = event;
        if (!Number.isFinite(time) || time < previousTime) {
            throw new Error('Recording timestamps must be finite and monotonic.');
        }
        previousTime = time;
        if (type === 'x' && data !== '0') throw new Error('Recorded command exited unsuccessfully.');
        if (['o', 'r', 'm'].includes(type)) lastVisualTime = time;
        output.push(event);
        if (type !== 'o') continue;
        // PTY reads can split a banner at any byte. Match complete lines only,
        // removing terminal controls without changing the saved terminal output.
        pending += data;
        const lastNewline = pending.lastIndexOf('\n');
        if (lastNewline === -1) continue;
        const complete = pending.slice(0, lastNewline + 1)
            .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
            .replace(/\r/g, '')
            .replace(/^=== (.*?) ===$/gm, '$1');
        pending = pending.slice(lastNewline + 1);
        for (const match of complete.matchAll(chapterPattern)) {
            const title = match[0];
            // MP4 chapter boundaries use milliseconds, even for faster PTY reads.
            if (Math.round((chapters.at(-1)?.time ?? -1) * 1000) === Math.round(time * 1000)) {
                chapters.at(-1).title += ` / ${title}`;
                lastMarker[2] = chapters.at(-1).title;
            } else {
                chapters.push({ time, title });
                lastMarker = [time, 'm', title];
                output.push(lastMarker);
            }
        }
    }
    if (!chapters.at(-1)?.title.includes('RECORDING COMPLETE:')) {
        throw new Error('Missing completion checkpoint; refusing to publish an incomplete demo.');
    }
    const duration = lastVisualTime + 3;
    const escape = value => value.replace(/[\\=;#\n]/g, '\\$&');
    const metadata = [';FFMETADATA1', `title=${escape(header.title ?? 'Offline demo')}`];
    const timestamps = [];
    chapters.forEach(({ time, title }, index) => {
        const start = index === 0 ? 0 : Math.round(time * 1000);
        const end = Math.round((chapters[index + 1]?.time ?? duration) * 1000);
        if (end <= start) throw new Error('Chapter boundaries are too close together.');
        metadata.push('[CHAPTER]', 'TIMEBASE=1/1000', `START=${start}`, `END=${end}`, `title=${escape(title)}`);
        const seconds = Math.floor(start / 1000);
        timestamps.push(`${String(Math.floor(seconds / 3600)).padStart(2, '0')}:${String(Math.floor(seconds / 60) % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}  ${title}`);
    });
    return {
        cast: [JSON.stringify(header), ...output.map(event => JSON.stringify(event))].join('\n') + '\n',
        metadata: metadata.join('\n') + '\n',
        timestamps: timestamps.join('\n') + '\n',
        chapters,
        duration,
    };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const directory = process.argv[2];
    if (!directory) throw new Error('Usage: node scripts/recording-chapters.mjs RECORDING_DIRECTORY');
    const result = finalize(readFileSync(join(directory, 'raw.cast'), 'utf8'));
    for (const [name, content] of [
        ['demo.cast', result.cast],
        ['chapters.ffmetadata', result.metadata],
        ['chapters.txt', result.timestamps],
    ]) {
        writeFileSync(join(directory, name), content, { flag: 'wx', mode: 0o600 });
    }
    console.log(`Finalized ${result.chapters.length} narration checkpoints; ${result.duration.toFixed(1)} seconds.`);
}
