#!/usr/bin/env node
/**
 * FIRE 에어드롭 Merkle 출력물 독립 검증기.
 *
 *   node verify.mjs --dir <generate.mjs 출력 디렉터리> [--expected-total <FIRE>] [--round <n>] [--deny <주소,…>]
 *   node verify.mjs --tree <tree.json> --merkle <merkle.json> [--recipients <csv>] [--expected-total <FIRE>] [--round <n>]
 *
 * tree.json을 다시 로드해 모든 노드를 재계산하고, 트리의 leaf가 정확히 values뿐인지(숨은 할당 없음) 확인하며,
 * 모든 수령자의 proof를 root에 대해 검증하고(OpenZeppelin 라이브러리 + Solidity와 같은 독립 계산),
 * merkle.json의 root·total·totalFire·count·claims와 recipients.csv를 주소·수량 단위로 전수 대조한다.
 * 공개된 파일을 제3자가 검증할 때도 이 스크립트를 그대로 쓸 수 있다.
 *
 * 종료 코드: 0 통과, 1 검증 실패, 2 사용법·파일 오류
 */
import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import {
  AirdropInputError,
  formatFire,
  parseDenyList,
  parseFireAmount,
  parseRound,
  verifyAirdrop,
} from './lib/airdrop.mjs';

const USAGE = `사용법:
  node verify.mjs --dir <출력 디렉터리> [--expected-total <FIRE>] [--round <n>] [--deny <주소,…>]
  node verify.mjs --tree <tree.json> --merkle <merkle.json> [--recipients <recipients.csv>] [--expected-total <FIRE>] [--round <n>] [--deny <주소,…>]

  --deny  수령자가 될 수 없는 주소 (쉼표로 구분, 여러 번 지정 가능). 예약 대역은 이 옵션 없이도 항상 거부`;

class UsageError extends Error {}

function readText(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch (error) {
    throw new UsageError(`파일을 읽을 수 없습니다: ${path} (${error.code ?? error.message})`);
  }
}

function readJson(path) {
  const text = readText(path);
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new UsageError(`JSON 파싱 실패: ${path} (${error.message})`);
  }
}

function main(argv) {
  let args;
  try {
    ({ values: args } = parseArgs({
      args: argv,
      strict: true,
      allowPositionals: false,
      options: {
        dir: { type: 'string' },
        tree: { type: 'string' },
        merkle: { type: 'string' },
        recipients: { type: 'string' },
        'expected-total': { type: 'string' },
        round: { type: 'string' },
        deny: { type: 'string', multiple: true, default: [] },
        help: { type: 'boolean', short: 'h', default: false },
      },
    }));
  } catch (error) {
    throw new UsageError(error.message);
  }
  if (args.help) {
    console.log(USAGE);
    return 0;
  }

  let treePath;
  let merklePath;
  let recipientsPath;
  if (args.dir !== undefined) {
    if (args.tree !== undefined || args.merkle !== undefined || args.recipients !== undefined) {
      throw new UsageError('--dir 와 --tree/--merkle/--recipients 는 함께 쓸 수 없습니다');
    }
    const dir = resolve(args.dir);
    treePath = join(dir, 'tree.json');
    merklePath = join(dir, 'merkle.json');
    recipientsPath = join(dir, 'recipients.csv');
    if (!existsSync(recipientsPath)) throw new UsageError(`공개용 recipients.csv가 없습니다: ${recipientsPath}`);
  } else {
    if (args.tree === undefined || args.merkle === undefined) {
      throw new UsageError('--dir 또는 --tree 와 --merkle 이 필요합니다');
    }
    treePath = resolve(args.tree);
    merklePath = resolve(args.merkle);
    recipientsPath = args.recipients === undefined ? undefined : resolve(args.recipients);
  }

  let expectedTotal;
  let expectedRound;
  let deny;
  try {
    if (args['expected-total'] !== undefined) {
      expectedTotal = parseFireAmount(args['expected-total'], '--expected-total');
    }
    if (args.round !== undefined) expectedRound = parseRound(args.round);
    deny = parseDenyList(args.deny);
  } catch (error) {
    if (error instanceof AirdropInputError) throw new UsageError(error.message);
    throw error;
  }

  const result = verifyAirdrop({
    treeData: readJson(treePath),
    merkleData: readJson(merklePath),
    recipientsText: recipientsPath === undefined ? undefined : readText(recipientsPath),
    expectedTotal,
    expectedRound,
    deny,
  });

  if (result.errors.length > 0) {
    console.error(`\n✖ 검증 실패 (${result.errors.length}건): ${merklePath}`);
    for (const error of result.errors) console.error(`  - [${error.code}] ${error.message}`);
    console.error('');
    return 1;
  }

  console.log(`✔ 검증 통과: ${merklePath}
  회차 (round)      : ${result.round}
  Merkle Root       : ${result.root}
  수령자 수         : ${result.count} (모든 proof가 root에 대해 유효)
  트리 leaf 수      : ${result.leafCount} (values와 같음: 목록에 없는 숨은 leaf 없음)
  총량              : ${formatFire(result.total)} FIRE (${result.total} wei)
  recipients.csv    : ${recipientsPath === undefined ? '대조 생략 (--recipients 미지정)' : `일치 (${result.count}명, 주소·수량 전수 대조)`}
  기대 총량 대조    : ${expectedTotal === undefined ? '생략 (--expected-total 미지정)' : '일치'}`);
  return 0;
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (error) {
  if (error instanceof UsageError) {
    console.error(`✖ ${error.message}\n\n${USAGE}`);
    process.exitCode = 2;
  } else {
    throw error;
  }
}
