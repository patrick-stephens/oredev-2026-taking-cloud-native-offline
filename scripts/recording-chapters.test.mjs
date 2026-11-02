import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { finalize } from './recording-chapters.mjs';

const cast = events => [
    JSON.stringify({ version: 2, width: 120, height: 36, idle_time_limit: 2, title: 'Demo; #1=offline' }),
    ...events.map(event => JSON.stringify(event)),
].join('\n') + '\n';

test('preserves real output and timings and adds split-banner checkpoints', () => {
    const events = [
        [0.1, 'o', '\x1b[H\x1b[2J\r\n=== PH'],
        [0.2, 'o', 'ASE 1: CONNECTED - package ===\r\n'],
        [34, 'o', '$ printf "egress=blocked\\n"\r\negress=blocked\r\n'],
        [35, 'o', 'PROVED: external HTTP blocked.\r\n'],
        [40, 'o', 'RECORDING COMPLETE: adv-01 succeeded.\r\n'],
    ];
    const result = finalize(cast(events));
    const [header, ...output] = result.cast.trimEnd().split('\n').map(line => JSON.parse(line));
    assert.equal(header.idle_time_limit, undefined);
    assert.deepEqual(output.filter(event => event[1] === 'o'), events);
    assert.equal(result.chapters.length, 3);
    assert.equal(result.chapters[0].time, 0.2);
    assert.equal(result.duration, 43);
    assert.match(result.metadata, /START=40000\nEND=43000/);
    assert.match(result.metadata, /title=Demo\\; \\#1\\=offline/);
    assert.match(result.timestamps, /00:00:40  RECORDING COMPLETE/);
});

test('recognizes actual Zarf phase decorations', () => {
    const result = finalize(cast([
        [1, 'o', '=== PHASE 1: CONNECTED - package ===\r\n'],
        [3, 'o', 'RECORDING COMPLETE: adv-01 succeeded.\r\n'],
    ]));
    assert.match(result.chapters[0].title, /PHASE 1: CONNECTED/);
});

test('recognizes live phases and tamper rejection', () => {
    const result = finalize(cast([
        [1, 'o', '1 / CONNECTED: package\r\n'],
        [10, 'o', 'PASS: tampered image rejected before import or deployment.\r\n'],
        [15, 'o', 'RECORDING COMPLETE: live-2 succeeded.\r\n'],
    ]));
    assert.equal(result.chapters.length, 3);
    assert.match(result.metadata, /START=10000/);
});

test('coalesces checkpoints delivered in the same PTY event', () => {
    const result = finalize(cast([
        [1, 'o', 'PROVED: isolated.\nINITIALIZED: local registry.\n'],
        [2, 'o', 'RECORDING COMPLETE: adv-01 succeeded.\n'],
    ]));
    assert.equal(result.chapters.length, 2);
    assert.equal(result.chapters[0].title, 'PROVED: isolated. / INITIALIZED: local registry.');
});

test('coalesces sub-millisecond checkpoints without modifying output events', () => {
    const events = [
        [1.0001, 'o', 'PROVED: isolated.\n'],
        [1.0002, 'o', 'INITIALIZED: local registry.\n'],
        [2, 'o', 'RECORDING COMPLETE: adv-01 succeeded.\n'],
    ];
    const result = finalize(cast(events));
    const output = result.cast.trimEnd().split('\n').slice(1).map(line => JSON.parse(line));
    assert.deepEqual(output.filter(event => event[1] === 'o'), events);
    assert.equal(result.chapters.length, 2);
    assert.equal(result.chapters[0].title, 'PROVED: isolated. / INITIALIZED: local registry.');
});

test('rejects empty, failed, malformed and non-monotonic captures', () => {
    assert.throws(() => finalize(cast([])), /no events/);
    assert.throws(() => finalize(cast([[1, 'o', 'ERROR: demo failed\n']])), /incomplete/);
    assert.throws(() => finalize('{}\n'), /asciicast v2/);
    assert.throws(() => finalize(cast([[2, 'o', 'a\n'], [1, 'o', 'b\n']])), /monotonic/);
    assert.throws(() => finalize(cast([[1, 'x', '42']])), /unsuccessfully/);
});

test('uses the visual timeline, not the later process exit, for the MP4 end', () => {
    const result = finalize(cast([
        [1, 'o', '1 / START: cache\n'],
        [10, 'o', 'RECORDING COMPLETE: live-1 succeeded.\n'],
        [13, 'x', '0'],
    ]));
    assert.equal(result.duration, 13);
    assert.match(result.metadata, /START=10000\nEND=13000/);
});

for (const [path, command, waits] of [
    ['../live-demos/1-pull-through-cache-zot/scripts/common.sh', 'banner', ['3']],
    ['../live-demos/2-offline-bundle-cosign/scripts/common.sh', 'banner', ['3']],
    ['../advanced-demos/zarf-package-lifecycle/scripts/common.sh', 'phase', ['1', '3', '1']],
]) {
    test(`${path}: adds a hold only in recording mode`, () => {
        const result = spawnSync('bash', ['-c', `
            source "$1"
            sleep() { printf 'WAIT:%s\\n' "$1"; }
            DEMO_RECORDING=0 "$2" 'Test phase'
            DEMO_RECORDING=1 "$2" 'Test phase'
        `, 'test', fileURLToPath(new URL(path, import.meta.url)), command], { encoding: 'utf8' });
        assert.equal(result.status, 0, result.stderr);
        assert.deepEqual([...result.stdout.matchAll(/WAIT:(\d+)/g)].map(match => match[1]), waits);
        assert.equal([...result.stdout.matchAll(/Test phase/g)].length, 2);
    });
    test(`${path}: runs inspections only when sourced in recording mode`, () => {
        for (const mode of ['0', '1']) {
            const result = spawnSync('bash', ['-c', `
                export DEMO_RECORDING="$2"
                source "$1"
                sleep() { :; }
                record_commands 'printf "stage-evidence\\n"'
            `, 'test', fileURLToPath(new URL(path, import.meta.url)), mode], { encoding: 'utf8' });
            assert.equal(result.status, 0, result.stderr);
            assert.equal(result.stdout.includes('stage-evidence\n'), mode === '1');
        }
    });
}

test('recording inspections include commands and output only in recording mode', () => {
    const helper = fileURLToPath(new URL('./recording-inspect.sh', import.meta.url));
    const result = spawnSync('bash', ['-c', `
        source "$1"
        sleep() { :; }
        DEMO_RECORDING=0 record_commands 'printf SHOULD_NOT_RUN'
        DEMO_RECORDING=1 record_commands 'printf "inspection-output\\n"'
    `, 'test', helper], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stdout, /SHOULD_NOT_RUN/);
    assert.match(result.stdout, /\$ printf "inspection-output\\n"\ninspection-output\n/);
});

test('recording inspections propagate failures, including failed pipelines', () => {
    const helper = fileURLToPath(new URL('./recording-inspect.sh', import.meta.url));
    for (const command of ['exit 7', 'false | cat']) {
        const result = spawnSync('bash', ['-c', `
            source "$1"
            DEMO_RECORDING=1 record_commands "$2"
        `, 'test', helper, command], { encoding: 'utf8' });
        assert.equal(result.status, command === 'exit 7' ? 7 : 1, result.stderr);
    }
});
