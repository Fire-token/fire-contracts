// FIRE 에어드롭 도구 테스트 (node:test). 실행: npm test
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import {
  AirdropInputError,
  CSV_HEADER,
  LEAF_ENCODING,
  MAX_SUPPLY_WEI,
  buildAirdrop,
  checksumAddress,
  formatFire,
  leafHash,
  normalizeAddress,
  parseDenyList,
  parseFireAmount,
  parseRecipientsCsv,
  parseRound,
  processProof,
  sumAmounts,
  toJson,
  toRecipientsCsv,
  verifyAirdrop,
} from '../lib/airdrop.mjs';
import { buildSampleFixtures } from '../fixture.mjs';

const TOOL_DIR = dirname(dirname(fileURLToPath(import.meta.url)));
const SAMPLE_CSV = readFileSync(join(TOOL_DIR, 'sample.csv'), 'utf8');
const CHECKSUMMED = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
const SCRATCH = mkdtempSync(join(tmpdir(), 'fire-airdrop-test-'));
after(() => rmSync(SCRATCH, { recursive: true, force: true }));

function csv(...rows) {
  return [CSV_HEADER, ...rows].join('\n') + '\n';
}

function codeOf(fn) {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof AirdropInputError, `unexpected error: ${error}`);
    return error.code;
  }
  assert.fail('expected AirdropInputError');
}

function runCli(script, args) {
  return spawnSync(process.execPath, [join(TOOL_DIR, script), ...args], { encoding: 'utf8' });
}

function sampleBuild() {
  const { entries, errors } = parseRecipientsCsv(SAMPLE_CSV);
  assert.deepEqual(errors, []);
  return buildAirdrop(entries, { round: 1 });
}

/**
 * 리뷰 PoC 재현: root는 목록에 없는 leaf(내부자 300 FIRE)까지 포함하지만, tree.json values와 merkle.json claims에서는
 * 그 항목을 뺀 출력물. withHiddenRow면 공개용 recipients.csv에는 그 행을 넣는다(10행·1300 FIRE).
 */
const HIDDEN = Object.freeze(['0x00000000000000000000000000000000DeaDBeef', (300n * 10n ** 18n).toString()]);
function hiddenLeafOutput({ withHiddenRow }) {
  const { entries } = parseRecipientsCsv(SAMPLE_CSV);
  const visible = [...entries]
    .sort((a, b) => (a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1))
    .map(({ address, amount }) => [address, amount.toString()]);
  const full = StandardMerkleTree.of([...visible, HIDDEN], [...LEAF_ENCODING]);
  const treeData = full.dump();
  treeData.values = treeData.values.slice(0, visible.length);
  const claims = {};
  let total = 0n;
  visible.forEach(([address, amount], index) => {
    claims[address] = { amount, proof: full.getProof(index) };
    total += BigInt(amount);
  });
  const merkleData = { round: 1, root: full.root, total: total.toString(), totalFire: formatFire(total), count: 9, claims };
  const hiddenEntry = { address: normalizeAddress(HIDDEN[0]), amount: BigInt(HIDDEN[1]) };
  const recipientsText = toRecipientsCsv(withHiddenRow ? [...entries, hiddenEntry] : entries);
  return { treeData, merkleData, recipientsText, hiddenProof: full.getProof(visible.length) };
}

describe('normalizeAddress', () => {
  it('accepts checksummed, all-lowercase and all-uppercase hex', () => {
    assert.equal(normalizeAddress(CHECKSUMMED), CHECKSUMMED);
    assert.equal(normalizeAddress(CHECKSUMMED.toLowerCase()), CHECKSUMMED);
    assert.equal(normalizeAddress(`0x${CHECKSUMMED.slice(2).toUpperCase()}`), CHECKSUMMED);
    assert.equal(normalizeAddress(`  ${CHECKSUMMED}  `), CHECKSUMMED);
  });

  it('rejects mixed-case addresses with a wrong EIP-55 checksum', () => {
    const wrong = `${CHECKSUMMED.slice(0, -1)}D`;
    assert.equal(codeOf(() => normalizeAddress(wrong)), 'ADDRESS_CHECKSUM');
  });

  it('rejects malformed and zero addresses', () => {
    for (const bad of ['', '0x', '0x1234', `0X${CHECKSUMMED.slice(2)}`, `${CHECKSUMMED}00`, 'vitalik.eth']) {
      assert.equal(codeOf(() => normalizeAddress(bad)), 'ADDRESS_FORMAT', bad);
    }
    assert.equal(codeOf(() => normalizeAddress(`0x${'0'.repeat(40)}`)), 'ADDRESS_ZERO');
  });
});

describe('recipient policy (reserved ranges, --deny)', () => {
  // 리뷰 PoC(F5) 회귀: 예전에는 아래 주소가 모두 생성·검증을 통과했음. claim은 누구나 대신 제출할 수 있으므로
  // 목록에 들어간 순간 그 몫은 소각·동결되어 sweep으로도 돌아오지 않음.
  const RESERVED = [
    '0x000000000000000000000000000000000000dEaD', // 소각 관례 주소
    '0x0000000000000000000000000000000000000001', // ecrecover 프리컴파일
    '0x0000000000000000000000000000000000000100', // Base P256VERIFY 프리컴파일
    '0x000000000000000000000000000000000000FFff', // 하위 예약 대역의 끝
    '0x4200000000000000000000000000000000000006', // Base WETH 프리디플로이
    '0x4200000000000000000000000000000000000016', // L2ToL1MessagePasser
    '0x420000000000000000000000000000000000FffF', // 프리디플로이 대역의 끝
  ];

  it('rejects precompiles, burn addresses and OP Stack predeploys', () => {
    for (const address of RESERVED) {
      assert.equal(codeOf(() => normalizeAddress(address)), 'ADDRESS_RESERVED', address);
      assert.equal(codeOf(() => normalizeAddress(address.toLowerCase())), 'ADDRESS_RESERVED', address);
      assert.equal(checksumAddress(address), address); // 형식·체크섬만 보는 함수는 통과
    }
    const csvText = csv(...RESERVED.map((address) => `${address},100`), `${CHECKSUMMED},1`);
    const { entries, errors } = parseRecipientsCsv(csvText);
    assert.deepEqual(entries.map((e) => e.address), [CHECKSUMMED]);
    assert.deepEqual(
      errors.map((e) => [e.line, e.code]),
      RESERVED.map((_, i) => [i + 2, 'ADDRESS_RESERVED']),
    );
  });

  it('accepts addresses just outside the reserved ranges', () => {
    for (const address of [
      '0x0000000000000000000000000000000000010000',
      '0x41ffffffffffffffffffffffffffffffffffffff',
      '0x4200000000000000000000000000000000010000',
    ]) {
      assert.equal(normalizeAddress(address), checksumAddress(address));
    }
  });

  it('rejects --deny addresses with their line numbers and validates the deny list itself', () => {
    const deny = parseDenyList([`${CHECKSUMMED.toLowerCase()}, 0x${'7'.repeat(40)}`]);
    assert.deepEqual([...deny], [CHECKSUMMED, checksumAddress(`0x${'7'.repeat(40)}`)]);
    const { entries, errors } = parseRecipientsCsv(csv(`0x${'1'.repeat(40)},1`, `${CHECKSUMMED},2`), { deny });
    assert.equal(entries.length, 1);
    assert.deepEqual(
      errors.map((e) => [e.line, e.code]),
      [[3, 'DENIED']],
    );
    assert.equal(codeOf(() => parseDenyList([`${CHECKSUMMED.slice(0, -1)}D`])), 'ADDRESS_CHECKSUM');
    assert.equal(codeOf(() => parseDenyList(['0x1234'])), 'ADDRESS_FORMAT');
  });

  it('verify rejects trees that pay a reserved or denied address', () => {
    const values = [
      [RESERVED[4], (1n * 10n ** 18n).toString()],
      [CHECKSUMMED, (2n * 10n ** 18n).toString()],
    ];
    const tree = StandardMerkleTree.of(values, [...LEAF_ENCODING]);
    const claims = {};
    for (const [index, [address, amount]] of tree.entries()) claims[address] = { amount, proof: tree.getProof(index) };
    const merkleData = { round: 1, root: tree.root, total: (3n * 10n ** 18n).toString(), totalFire: '3', count: 2, claims };
    const codes = verifyAirdrop({ treeData: tree.dump(), merkleData }).errors.map((e) => e.code);
    assert.ok(codes.includes('TREE_ADDRESS'));

    const { files } = sampleBuild();
    const deny = parseDenyList([Object.keys(JSON.parse(files['merkle.json']).claims)[0]]);
    const result = verifyAirdrop({
      treeData: JSON.parse(files['tree.json']),
      merkleData: JSON.parse(files['merkle.json']),
      recipientsText: files['recipients.csv'],
      deny,
    });
    assert.ok(result.errors.some((e) => e.code === 'TREE_DENIED'));
    assert.ok(result.errors.some((e) => e.code === 'RECIPIENTS_INVALID' && e.message.includes('DENIED')));
  });
});

describe('parseFireAmount', () => {
  it('parses whole and fractional FIRE exactly (up to 18 decimals)', () => {
    assert.equal(parseFireAmount('1'), 10n ** 18n);
    assert.equal(parseFireAmount('75.5'), 755n * 10n ** 17n);
    assert.equal(parseFireAmount('0.000000000000000001'), 1n);
    assert.equal(parseFireAmount('20000000'), 20_000_000n * 10n ** 18n);
    assert.equal(parseFireAmount('1000000000'), MAX_SUPPLY_WEI);
  });

  it('rejects zero, signs, exponents, separators and bad shapes', () => {
    assert.equal(codeOf(() => parseFireAmount('0')), 'AMOUNT_ZERO');
    assert.equal(codeOf(() => parseFireAmount('0.000')), 'AMOUNT_ZERO');
    for (const bad of ['', '-1', '+1', '1e3', '1_000', '1 000', '.5', '5.', '0x10', 'abc', '1.2.3']) {
      assert.equal(codeOf(() => parseFireAmount(bad)), 'AMOUNT_FORMAT', bad);
    }
  });

  it('rejects more than 18 decimals instead of rounding', () => {
    assert.equal(codeOf(() => parseFireAmount('1.0000000000000000001')), 'AMOUNT_DECIMALS');
  });

  it('rejects amounts above total supply', () => {
    assert.equal(codeOf(() => parseFireAmount('1000000000.000000000000000001')), 'AMOUNT_TOO_LARGE');
  });
});

describe('parseRound', () => {
  it('accepts positive integers only', () => {
    assert.equal(parseRound('1'), 1);
    assert.equal(parseRound('2'), 2);
    for (const bad of ['0', '-1', '1.5', 'one', '', '01']) {
      assert.equal(codeOf(() => parseRound(bad)), 'ROUND_FORMAT', bad);
    }
  });
});

describe('parseRecipientsCsv', () => {
  it('parses the sample: 9 recipients totalling exactly 1000 FIRE', () => {
    const { entries, errors } = parseRecipientsCsv(SAMPLE_CSV);
    assert.deepEqual(errors, []);
    assert.equal(entries.length, 9);
    assert.equal(sumAmounts(entries), 1000n * 10n ** 18n);
  });

  it('requires the header', () => {
    const { errors } = parseRecipientsCsv(`${CHECKSUMMED},1\n`);
    assert.deepEqual(
      errors.map((e) => [e.line, e.code]),
      [[1, 'HEADER']],
    );
  });

  it('tolerates BOM, CRLF, header case and blank lines while keeping line numbers', () => {
    const text = `﻿Address , Amount\r\n${CHECKSUMMED},1\r\n\r\n0x${'1'.repeat(40)},bad\r\n`;
    const { entries, errors } = parseRecipientsCsv(text);
    assert.equal(entries.length, 1);
    assert.deepEqual(
      errors.map((e) => [e.line, e.code]),
      [[4, 'AMOUNT_FORMAT']],
    );
  });

  it('collects every error with its line number in one pass', () => {
    const lower = CHECKSUMMED.toLowerCase();
    const text = csv(
      `${CHECKSUMMED.slice(0, -1)}D,1`, // 2: checksum
      `0x${'0'.repeat(40)},1`, // 3: zero
      `${lower},2`, // 4: duplicate of line 2 (case-insensitive)
      '0xabc,1', // 5: format
      `0x${'2'.repeat(40)},0`, // 6: zero amount
      `0x${'3'.repeat(40)},"1,000"`, // 7: columns
      `0x${'4'.repeat(40)},1.0000000000000000001`, // 8: decimals
    );
    const { entries, errors } = parseRecipientsCsv(text);
    assert.equal(entries.length, 0);
    assert.deepEqual(
      errors.map((e) => [e.line, e.code]),
      [
        [2, 'ADDRESS_CHECKSUM'],
        [3, 'ADDRESS_ZERO'],
        [4, 'DUPLICATE'],
        [5, 'ADDRESS_FORMAT'],
        [6, 'AMOUNT_ZERO'],
        [7, 'COLUMNS'],
        [8, 'AMOUNT_DECIMALS'],
      ],
    );
    assert.match(errors[2].message, /2행/);
  });

  it('rejects an empty recipient list', () => {
    assert.deepEqual(
      parseRecipientsCsv(`${CSV_HEADER}\n\n`).errors.map((e) => e.code),
      ['EMPTY'],
    );
  });
});

describe('buildAirdrop', () => {
  it('is deterministic regardless of CSV row order and address case', () => {
    const reference = sampleBuild();
    const [header, ...rows] = SAMPLE_CSV.trim().split('\n');
    const variant = [header, ...rows.reverse().map((row) => row.toLowerCase())].join('\r\n');
    const parsed = parseRecipientsCsv(variant);
    assert.deepEqual(parsed.errors, []);
    const again = buildAirdrop(parsed.entries, { round: 1 });
    assert.equal(again.merkle.root, reference.merkle.root);
    assert.deepEqual(again.files, reference.files);
  });

  it('produces merkle.json with the documented shape', () => {
    const { merkle } = sampleBuild();
    assert.deepEqual(Object.keys(merkle), ['round', 'root', 'total', 'totalFire', 'count', 'claims']);
    assert.equal(merkle.round, 1);
    assert.match(merkle.root, /^0x[0-9a-f]{64}$/);
    assert.equal(merkle.total, (1000n * 10n ** 18n).toString());
    assert.equal(merkle.totalFire, '1000');
    assert.equal(merkle.count, 9);
    const addresses = Object.keys(merkle.claims);
    assert.deepEqual(addresses, [...addresses].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase())));
    for (const address of addresses) assert.equal(normalizeAddress(address), address);
  });

  it('matches the Solidity leaf/proof algorithm (independent viem implementation)', () => {
    const { tree, merkle } = sampleBuild();
    for (const [index, [address, amount]] of tree.entries()) {
      assert.equal(leafHash(address, amount), tree.leafHash([address, amount]));
      assert.equal(processProof(leafHash(address, amount), merkle.claims[address].proof), merkle.root);
      assert.deepEqual(merkle.claims[address].proof, tree.getProof(index));
    }
  });

  it('round-trips through the public recipients.csv to the same root', () => {
    const { merkle, files } = sampleBuild();
    const reparsed = parseRecipientsCsv(files['recipients.csv']);
    assert.deepEqual(reparsed.errors, []);
    assert.equal(buildAirdrop(reparsed.entries, { round: 1 }).merkle.root, merkle.root);
  });

  it('refuses duplicates and non-positive amounts even when called directly', () => {
    const entry = { address: CHECKSUMMED, amount: 1n };
    assert.throws(() => buildAirdrop([entry, { ...entry }], { round: 1 }), /중복/);
    assert.throws(() => buildAirdrop([{ ...entry, amount: 0n }], { round: 1 }), /수량/);
    assert.throws(() => buildAirdrop([entry], { round: 0 }), /round/);
  });

  it('supports a single recipient (empty proof, root = leaf)', () => {
    const { merkle } = buildAirdrop([{ address: CHECKSUMMED, amount: 5n }], { round: 1 });
    assert.deepEqual(merkle.claims[CHECKSUMMED].proof, []);
    assert.equal(merkle.root, leafHash(CHECKSUMMED, 5n));
  });
});

describe('verifyAirdrop', () => {
  const pristine = () => {
    const { files } = sampleBuild();
    return {
      treeData: JSON.parse(files['tree.json']),
      merkleData: JSON.parse(files['merkle.json']),
      recipientsText: files['recipients.csv'],
      expectedTotal: 1000n * 10n ** 18n,
      expectedRound: 1,
    };
  };
  const codes = (input) => verifyAirdrop(input).errors.map((e) => e.code);
  const firstAddress = (input) => Object.keys(input.merkleData.claims)[0];

  it('accepts untouched output', () => {
    const result = verifyAirdrop(pristine());
    assert.deepEqual(result.errors, []);
    assert.equal(result.count, 9);
    assert.equal(result.total, 1000n * 10n ** 18n);
  });

  it('detects a tampered claim amount', () => {
    const input = pristine();
    input.merkleData.claims[firstAddress(input)].amount = '1';
    assert.ok(codes(input).includes('CLAIM_AMOUNT'));
  });

  it('detects a tampered proof', () => {
    const input = pristine();
    const claim = input.merkleData.claims[firstAddress(input)];
    claim.proof[0] = `0x${'ab'.repeat(32)}`;
    assert.ok(codes(input).includes('CLAIM_PROOF'));
    assert.ok(codes(input).includes('PROOF_INVALID'));
  });

  it('detects extra and missing claims', () => {
    const extra = pristine();
    extra.merkleData.claims[CHECKSUMMED] = { amount: '1', proof: [] };
    assert.ok(codes(extra).includes('CLAIM_EXTRA'));

    const missing = pristine();
    delete missing.merkleData.claims[firstAddress(missing)];
    assert.ok(codes(missing).includes('CLAIM_MISSING'));
  });

  it('detects wrong root, totals, count and round', () => {
    const input = pristine();
    input.merkleData.root = `0x${'11'.repeat(32)}`;
    input.merkleData.total = '1';
    input.merkleData.totalFire = '999';
    input.merkleData.count = 8;
    input.merkleData.round = 0;
    assert.deepEqual(
      codes(input).sort(),
      ['COUNT_MISMATCH', 'ROOT_MISMATCH', 'ROUND_INVALID', 'ROUND_MISMATCH', 'TOTAL_FIRE_MISMATCH', 'TOTAL_MISMATCH'],
    );
  });

  it('detects an unexpected total and round', () => {
    const input = { ...pristine(), expectedTotal: 20_000_000n * 10n ** 18n, expectedRound: 2 };
    assert.deepEqual(codes(input).sort(), ['EXPECTED_TOTAL_MISMATCH', 'ROUND_MISMATCH']);
  });

  it('detects a tampered tree.json value', () => {
    const input = pristine();
    input.treeData.values[0].value[1] = '1';
    assert.deepEqual(codes(input), ['TREE_INVALID']);
  });

  it('detects a recipients.csv that does not match the tree', () => {
    const input = pristine();
    input.recipientsText = input.recipientsText.replace(',250\n', ',251\n');
    assert.ok(codes(input).includes('RECIPIENTS_MISMATCH'));
  });

  it('rejects a root that commits to a leaf missing from values (hidden allocation)', () => {
    const { treeData, merkleData, hiddenProof } = hiddenLeafOutput({ withHiddenRow: false });
    // 숨은 leaf는 실제로 root에 대해 유효한 증명을 가짐 (컨트랙트에서 청구 가능)
    assert.ok(StandardMerkleTree.verify(merkleData.root, [...LEAF_ENCODING], HIDDEN, hiddenProof));
    const result = verifyAirdrop({ treeData, merkleData, expectedTotal: 1000n * 10n ** 18n, expectedRound: 1 });
    assert.deepEqual(result.errors.map((e) => e.code).sort(), ['TREE_EXTRA_LEAVES', 'TREE_REBUILD_MISMATCH']);
  });

  it('reports the hidden row and the count/total difference when recipients.csv lists it', () => {
    const input = { ...hiddenLeafOutput({ withHiddenRow: true }), expectedTotal: 1000n * 10n ** 18n, expectedRound: 1 };
    const { errors } = verifyAirdrop(input);
    const mismatches = errors.filter((e) => e.code === 'RECIPIENTS_MISMATCH').map((e) => e.message);
    assert.ok(errors.some((e) => e.code === 'TREE_EXTRA_LEAVES'));
    assert.ok(mismatches.some((m) => m.includes('10명') && m.includes('9명')));
    assert.ok(mismatches.some((m) => m.includes('1300 FIRE') && m.includes('1000 FIRE')));
    assert.ok(mismatches.some((m) => m.includes(normalizeAddress(HIDDEN[0]))));
  });

  it('rejects a tree with no values (arbitrary root, zero recipients)', () => {
    const root = `0x${'ab'.repeat(32)}`;
    const treeData = { format: 'standard-v1', leafEncoding: [...LEAF_ENCODING], tree: [root], values: [] };
    const merkleData = { round: 1, root, total: '0', totalFire: '0', count: 0, claims: {} };
    const codes = verifyAirdrop({ treeData, merkleData }).errors.map((e) => e.code);
    assert.ok(codes.includes('TREE_EMPTY'));
    assert.ok(codes.includes('TREE_EXTRA_LEAVES'));
  });

  it('rejects a complete but non-canonical tree (not produced by generate.mjs)', () => {
    const input = pristine();
    const values = input.treeData.values.map(({ value }) => value);
    input.treeData = StandardMerkleTree.of(values, [...LEAF_ENCODING], { sortLeaves: false }).dump();
    assert.ok(codes(input).includes('TREE_REBUILD_MISMATCH'));
  });

  it('compares recipients.csv with the tree entry by entry', () => {
    const missing = pristine();
    const [, firstRow] = missing.recipientsText.split('\n');
    missing.recipientsText = missing.recipientsText.replace(`${firstRow}\n`, '');
    const missingMessages = verifyAirdrop(missing).errors.map((e) => e.message);
    assert.ok(missingMessages.some((m) => m.includes(firstRow.split(',')[0]) && m.includes('recipients.csv에 없습니다')));

    const changed = pristine();
    changed.recipientsText = changed.recipientsText.replace(',250\n', ',251\n');
    const changedMessages = verifyAirdrop(changed).errors.map((e) => e.message);
    assert.ok(changedMessages.some((m) => m.includes('251 FIRE') && m.includes('250 FIRE')));
  });

  it('rejects trees with another leaf encoding', () => {
    const tree = StandardMerkleTree.of([[CHECKSUMMED, '1', '2']], ['address', 'uint256', 'uint256']);
    const input = { ...pristine(), treeData: tree.dump() };
    assert.deepEqual(codes(input), ['LEAF_ENCODING']);
  });
});

describe('CLI', () => {
  it('generate → verify succeeds, refuses to overwrite without --force', () => {
    const out = join(SCRATCH, 'round-1');
    const args = ['--input', join(TOOL_DIR, 'sample.csv'), '--out', out, '--expected-total', '1000', '--round', '1'];
    const generated = runCli('generate.mjs', args);
    assert.equal(generated.status, 0, generated.stderr);
    assert.match(generated.stdout, /0x[0-9a-f]{64}/);

    const verified = runCli('verify.mjs', ['--dir', out, '--expected-total', '1000', '--round', '1']);
    assert.equal(verified.status, 0, verified.stderr);

    const again = runCli('generate.mjs', args);
    assert.equal(again.status, 2);
    assert.match(again.stderr, /--force/);
    assert.equal(runCli('generate.mjs', [...args, '--force']).status, 0);
  });

  // 리허설 B1 회귀: 다음 단계 안내가 실제로 실행되는 명령이어야 함 (FIRE_TOKEN·CONFIRM_MAINNET 안내, 시뮬레이션 먼저)
  it('generate prints a simulation command first, then the --broadcast --slow command', () => {
    const out = join(SCRATCH, 'next-steps');
    const result = runCli('generate.mjs', [
      '--input', join(TOOL_DIR, 'sample.csv'), '--out', out, '--expected-total', '1000',
    ]);
    assert.equal(result.status, 0, result.stderr);
    const lines = result.stdout.split('\n').filter((line) => line.includes('forge script script/DeployAirdrop.s.sol'));
    assert.equal(lines.length, 2);
    assert.doesNotMatch(lines[0], /--broadcast/);
    assert.match(lines[1], /--broadcast --slow/);
    for (const line of lines) assert.match(line, /--sender \$AIRDROP_WALLET/);
    assert.match(result.stdout, /FIRE_TOKEN/);
    assert.match(result.stdout, /CONFIRM_MAINNET=I_UNDERSTAND/);
    assert.match(result.stdout, /export AIRDROP_MERKLE_JSON=\S+ AIRDROP_EXPECTED_ROOT=0x[0-9a-f]{64}/);
  });

  it('generate and verify honour --deny', () => {
    const out = join(SCRATCH, 'deny');
    const [, firstRow] = SAMPLE_CSV.split('\n');
    const denied = firstRow.split(',')[0];
    const args = ['--input', join(TOOL_DIR, 'sample.csv'), '--out', out, '--expected-total', '1000'];
    const rejected = runCli('generate.mjs', [...args, '--deny', `${CHECKSUMMED},${denied}`]);
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /2행 \[DENIED\]/);
    assert.throws(() => readFileSync(join(out, 'merkle.json')));

    assert.equal(runCli('generate.mjs', args).status, 0);
    assert.equal(runCli('verify.mjs', ['--dir', out, '--deny', CHECKSUMMED]).status, 0);
    const verified = runCli('verify.mjs', ['--dir', out, '--deny', CHECKSUMMED, '--deny', denied]);
    assert.equal(verified.status, 1);
    assert.match(verified.stderr, /TREE_DENIED/);
    assert.equal(runCli('verify.mjs', ['--dir', out, '--deny', '0x1234']).status, 2);
  });

  it('generate fails loudly with line numbers and writes nothing', () => {
    const input = join(SCRATCH, 'bad.csv');
    writeFileSync(input, csv(`${CHECKSUMMED},1`, `${CHECKSUMMED.toLowerCase()},1`));
    const out = join(SCRATCH, 'bad-out');
    const result = runCli('generate.mjs', ['--input', input, '--out', out, '--expected-total', '2']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /3행 \[DUPLICATE\]/);
    assert.throws(() => readFileSync(join(out, 'merkle.json')));
  });

  it('generate fails when the total differs from --expected-total', () => {
    const out = join(SCRATCH, 'total');
    const result = runCli('generate.mjs', ['--input', join(TOOL_DIR, 'sample.csv'), '--out', out, '--expected-total', '20000000']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /TOTAL_MISMATCH/);
  });

  it('generate rejects missing options and bad flags with usage errors', () => {
    assert.equal(runCli('generate.mjs', ['--input', 'x.csv']).status, 2);
    assert.equal(runCli('generate.mjs', ['--bogus']).status, 2);
    assert.equal(
      runCli('generate.mjs', ['--input', 'x.csv', '--out', SCRATCH, '--expected-total', '1', '--round', '0']).status,
      2,
    );
  });

  it('verify rejects hidden-leaf output in --tree/--merkle and --dir modes', () => {
    const out = join(SCRATCH, 'hidden');
    mkdirSync(out, { recursive: true });
    const { treeData, merkleData, recipientsText } = hiddenLeafOutput({ withHiddenRow: true });
    writeFileSync(join(out, 'tree.json'), toJson(treeData));
    writeFileSync(join(out, 'merkle.json'), toJson(merkleData));
    writeFileSync(join(out, 'recipients.csv'), recipientsText);

    const files = runCli('verify.mjs', [
      '--tree', join(out, 'tree.json'), '--merkle', join(out, 'merkle.json'), '--expected-total', '1000', '--round', '1',
    ]);
    assert.equal(files.status, 1, files.stdout);
    assert.match(files.stderr, /TREE_EXTRA_LEAVES/);

    const dir = runCli('verify.mjs', ['--dir', out, '--expected-total', '1000', '--round', '1']);
    assert.equal(dir.status, 1, dir.stdout);
    assert.match(dir.stderr, /TREE_EXTRA_LEAVES/);
    assert.match(dir.stderr, /RECIPIENTS_MISMATCH/);
    assert.doesNotMatch(dir.stdout, /일치/);
  });

  it('verify fails on a tampered merkle.json', () => {
    const out = join(SCRATCH, 'tamper');
    assert.equal(
      runCli('generate.mjs', ['--input', join(TOOL_DIR, 'sample.csv'), '--out', out, '--expected-total', '1000'])
        .status,
      0,
    );
    const path = join(out, 'merkle.json');
    const merkle = JSON.parse(readFileSync(path, 'utf8'));
    const [first] = Object.keys(merkle.claims);
    merkle.claims[first].amount = '1';
    writeFileSync(path, JSON.stringify(merkle));
    const result = runCli('verify.mjs', ['--dir', out]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /CLAIM_AMOUNT/);
  });
});

describe('Deployment integration', () => {
  it('writes the merkle.json header layout that script/DeployAirdrop.s.sol streams (first 7 lines)', () => {
    const builds = [sampleBuild(), buildAirdrop([{ address: CHECKSUMMED, amount: 5n }], { round: 12 })];
    for (const { files } of builds) {
      const lines = files['merkle.json'].split('\n');
      assert.equal(lines[0], '{');
      assert.match(lines[1], /^ {2}"round": [1-9][0-9]*,$/);
      assert.match(lines[2], /^ {2}"root": "0x[0-9a-f]{64}",$/);
      assert.match(lines[3], /^ {2}"total": "[1-9][0-9]*",$/);
      assert.match(lines[4], /^ {2}"totalFire": "[0-9]+(\.[0-9]+)?",$/);
      assert.match(lines[5], /^ {2}"count": [1-9][0-9]*,$/);
      assert.equal(lines[6], '  "claims": {');
    }
    const script = readFileSync(join(TOOL_DIR, '..', 'script', 'DeployAirdrop.s.sol'), 'utf8');
    assert.ok(script.includes(`HEADER_CLAIMS_LINE = '  "claims": {'`), 'deploy script expects another claims line');
  });

  it('uses --slow on every documented broadcast command', () => {
    for (const file of ['README.md', 'generate.mjs', join('..', 'script', 'DeployAirdrop.s.sol')]) {
      const lines = readFileSync(join(TOOL_DIR, file), 'utf8')
        .split('\n')
        .filter((line) => line.includes('--broadcast'));
      assert.ok(lines.length > 0, `${file}: no broadcast command found`);
      for (const line of lines) assert.match(line, /--slow/, `${file}: ${line.trim()}`);
    }
  });

  // 리허설 B1 회귀: 저장소 전체 문서·스크립트 안내의 전송 명령도 --slow (DeployBatchSender 안내에 빠져 있었음).
  // 명령 줄만 대상으로 함: --broadcast와 함께 forge script·--rpc-url·--sender 중 하나가 있는 줄 (설명 문장은 제외)
  it('uses --slow on every forge script broadcast command across the repository docs', () => {
    const files = [
      join('..', 'README.md'),
      join('..', '.env.example'),
      join('..', 'deployments', 'README.md'),
      join('..', 'script', 'Deploy.s.sol'),
      join('..', 'script', 'CreatePool.s.sol'),
      join('..', 'script', 'DeployBatchSender.s.sol'),
      join('..', 'script', 'PostDeployCheck.s.sol'),
    ];
    let commands = 0;
    for (const file of files) {
      const lines = readFileSync(join(TOOL_DIR, file), 'utf8')
        .split('\n')
        .filter((line) => line.includes('--broadcast') && /forge script|--rpc-url|--sender/.test(line));
      commands += lines.length;
      for (const line of lines) assert.match(line, /--slow/, `${file}: ${line.trim()}`);
    }
    assert.ok(commands >= 5, `only ${commands} broadcast commands found`);
  });

  // 리허설 B1 회귀: forge script는 복수형 --mnemonic-derivation-paths(또는 --mnemonic-indexes)만 받음. 단수형은 cast 전용.
  it('documents the plural Ledger derivation flag for forge script and never pairs forge with the singular', () => {
    const files = [
      join('..', 'README.md'),
      join('..', '.env.example'),
      join('..', 'deployments', 'README.md'),
      join('..', 'script', 'Deploy.s.sol'),
    ];
    for (const file of files) {
      const text = readFileSync(join(TOOL_DIR, file), 'utf8');
      assert.match(text, /--mnemonic-derivation-paths/, `${file}: forge plural flag missing`);
      for (const line of text.split('\n')) {
        if (line.includes('forge script') && line.includes('--ledger')) {
          assert.doesNotMatch(line, /--mnemonic-derivation-path(?!s)/, `${file}: ${line.trim()}`);
        }
      }
    }
  });

  // 리허설 B1 회귀: cast 1.8.5는 정수 뒤에 과학 표기 주석("[1.7e9]")을 붙이므로 date에 넘길 CLAIM_DEADLINE은 첫 필드만 씀.
  it('converts CLAIM_DEADLINE with only the first field of the cast call output', () => {
    const readme = readFileSync(join(TOOL_DIR, 'README.md'), 'utf8');
    const feeds = readme.split('\n').filter((line) => line.includes('$(cast call') && line.includes('CLAIM_DEADLINE'));
    assert.ok(feeds.length > 0, 'README.md: no CLAIM_DEADLINE conversion found');
    for (const line of feeds) assert.match(line, /\| cut -d' ' -f1\)/, line.trim());
    assert.match(readme, /date -u -d @\$DL/);
    assert.match(readme, /TZ=Asia\/Seoul date -d @\$DL/);
    const script = readFileSync(join(TOOL_DIR, '..', 'script', 'DeployAirdrop.s.sol'), 'utf8');
    assert.match(script, /date -u -d @\$\(cast call /);
    assert.match(script, /\| cut -d' ' -f1\)/);
  });

  // 리허설 B1 회귀: UNCX는 Base 락커 주소를 소문자로만 공개함. 문서의 체크섬 주소가 포크 테스트가 실제 락커로 쓰는
  // 주소(Solidity 리터럴이라 컴파일러가 체크섬을 강제)와 같고, 소문자 원본을 체크섬 변환한 값과도 같아야 함.
  it('documents the checksummed UNCX V3.1 Base locker used by the fork tests', () => {
    const forkTest = readFileSync(join(TOOL_DIR, '..', 'test', 'fork', 'CreatePool.fork.t.sol'), 'utf8');
    const locker = forkTest.match(/UNCX_V3_LOCKER = (0x[0-9a-fA-F]{40});/)?.[1];
    assert.ok(locker, 'UNCX_V3_LOCKER constant not found');
    assert.equal(checksumAddress('0x231278edd38b00b07fbd52120cef685b9baebcc1'), locker);
    const records = readFileSync(join(TOOL_DIR, '..', 'deployments', 'README.md'), 'utf8');
    assert.ok(records.includes(locker), 'deployments/README.md: checksummed UNCX locker missing');
    assert.match(records, /cast to-check-sum-address/);
  });

  // 리허설 B1 회귀: 로컬 포크 리허설이 forge RPC 캐시(~/.foundry/cache/rpc)를 오염시키지 않도록 하는 안내 유지.
  it('keeps the local-fork rehearsal cache and dev-key warnings in the root README', () => {
    const readme = readFileSync(join(TOOL_DIR, '..', 'README.md'), 'utf8');
    assert.match(readme, /anvil --fork-url \S+ --no-storage-caching/);
    assert.match(readme, /모든 `forge script`에 `--no-storage-caching`/);
    assert.match(readme, /cast rpc evm_mine/);
    assert.match(readme, /forge cache clean base --blocks/);
    assert.match(readme, /anvil 기본 개발 계정을 그대로 쓰지 마십시오/);
  });

  it('does not git-ignore airdrop/out (round files must be committed before deployment)', (t) => {
    const rootIgnore = join(TOOL_DIR, '..', '.gitignore');
    if (spawnSync('git', ['--version']).status !== 0) return t.skip('git is not installed');
    if (!existsSync(rootIgnore)) return t.skip('project .gitignore not found');
    const repo = mkdtempSync(join(SCRATCH, 'git-'));
    assert.equal(spawnSync('git', ['init', '-q', repo]).status, 0);
    copyFileSync(rootIgnore, join(repo, '.gitignore'));
    mkdirSync(join(repo, 'airdrop'), { recursive: true });
    copyFileSync(join(TOOL_DIR, '.gitignore'), join(repo, 'airdrop', '.gitignore'));
    const ignored = (path) => {
      mkdirSync(join(repo, dirname(path)), { recursive: true });
      writeFileSync(join(repo, path), '');
      const result = spawnSync('git', ['-C', repo, '-c', 'core.excludesFile=', 'check-ignore', '-q', path]);
      assert.ok(result.status === 0 || result.status === 1, String(result.stderr));
      return result.status === 0;
    };
    for (const name of ['merkle.json', 'tree.json', 'recipients.csv']) {
      assert.equal(ignored(`airdrop/out/round-1/${name}`), false, name);
    }
    assert.equal(ignored('airdrop/out/.gitkeep'), false);
    assert.equal(ignored('out/FireToken.sol/FireToken.json'), true); // forge 빌드 출력은 계속 무시
    assert.equal(ignored('airdrop/node_modules/viem/package.json'), true);
    // 리허설 B1 회귀: 공개 기록은 추적, 로컬·임시 파일은 무시 (deployments/README.md 표와 같음)
    assert.equal(ignored('deployments/8453.json'), false);
    assert.equal(ignored('deployments/84532.json'), false);
    assert.equal(ignored('deployments/31337.json'), true);
    assert.equal(ignored('deployments/permit-8453.json'), true);
    assert.equal(ignored('deployments/test-deploy-x.json'), true);
    assert.equal(ignored('lcov.info'), true); // forge coverage --report lcov 결과
    assert.equal(ignored('broadcast/Deploy.s.sol/8453/run-latest.json'), false);
    assert.equal(ignored('broadcast/Deploy.s.sol/31337/run-latest.json'), true);
    // 루트 규칙이 /out/으로 앵커되어 있어 airdrop/.gitignore 없이도 airdrop/out은 무시되지 않음
    rmSync(join(repo, 'airdrop', '.gitignore'));
    assert.equal(ignored('airdrop/out/round-2/merkle.json'), false);
  });
});

describe('Foundry fixtures', () => {
  it('committed test/fixtures/airdrop-sample*.json are up to date with sample.csv', () => {
    for (const [name, content] of Object.entries(buildSampleFixtures())) {
      const committed = readFileSync(join(TOOL_DIR, '..', 'test', 'fixtures', name), 'utf8');
      assert.equal(committed, content, `${name} is stale: run "npm run fixture"`);
    }
  });
});
