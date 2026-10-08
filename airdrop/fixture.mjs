#!/usr/bin/env node
/**
 * Foundry 테스트용 샘플 픽스처 생성기 (sample.csv → test/fixtures/airdrop-sample*.json).
 *
 *   node fixture.mjs           픽스처 다시 쓰기
 *   node fixture.mjs --check   커밋된 픽스처가 sample.csv·현재 도구로 만든 결과와 바이트 단위로 같은지 확인
 *
 * airdrop-sample.json      = generate.mjs의 merkle.json과 같은 형식 (DeployAirdrop 테스트·Solidity 호환성 테스트용)
 * airdrop-sample-tree.json = generate.mjs의 tree.json과 같은 형식 (Solidity가 트리 전체 해시를 재계산해 비교)
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildAirdrop, parseFireAmount, parseRecipientsCsv, sumAmounts } from './lib/airdrop.mjs';

const TOOL_DIR = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = resolve(TOOL_DIR, '..', 'test', 'fixtures');
const SAMPLE_CSV = join(TOOL_DIR, 'sample.csv');
const SAMPLE_TOTAL = '1000';
const SAMPLE_ROUND = 1;

export const FIXTURES = Object.freeze({
  'airdrop-sample.json': 'merkle.json',
  'airdrop-sample-tree.json': 'tree.json',
});

/** sample.csv로 픽스처 파일 내용을 만든다 ({ 픽스처 파일명: 내용 }) */
export function buildSampleFixtures() {
  const { entries, errors } = parseRecipientsCsv(readFileSync(SAMPLE_CSV, 'utf8'));
  if (errors.length > 0) throw new Error(`sample.csv 검증 실패: ${JSON.stringify(errors)}`);
  if (sumAmounts(entries) !== parseFireAmount(SAMPLE_TOTAL)) throw new Error('sample.csv 합계가 1000 FIRE가 아닙니다');
  const { files } = buildAirdrop(entries, { round: SAMPLE_ROUND });
  return Object.fromEntries(Object.entries(FIXTURES).map(([fixture, source]) => [fixture, files[source]]));
}

function main(argv) {
  const check = argv.includes('--check');
  const fixtures = buildSampleFixtures();
  let stale = 0;
  for (const [name, content] of Object.entries(fixtures)) {
    const path = join(FIXTURE_DIR, name);
    if (check) {
      let current = null;
      try {
        current = readFileSync(path, 'utf8');
      } catch {
        // 없는 파일은 아래에서 stale로 처리
      }
      if (current !== content) {
        console.error(`✖ 픽스처가 최신이 아닙니다: ${path} (node fixture.mjs 로 다시 생성)`);
        stale++;
      }
    } else {
      writeFileSync(path, content);
      console.log(`작성: ${path}`);
    }
  }
  if (check && stale === 0) console.log('✔ 픽스처 최신 상태');
  return stale === 0 ? 0 : 1;
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
