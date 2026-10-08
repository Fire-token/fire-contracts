#!/usr/bin/env node
/**
 * FIRE 에어드롭 회차별 Merkle 목록 생성기.
 *
 *   node generate.mjs --input <recipients.csv> --out <dir> --expected-total <FIRE> [--round <n>] [--deny <주소,…>] [--force]
 *
 * 출력 (--out 디렉터리):
 *   tree.json       OpenZeppelin StandardMerkleTree dump (누구나 root를 재계산할 수 있는 전체 트리)
 *   merkle.json     { round, root, total(wei), totalFire, count, claims: { 주소: { amount(wei), proof } } }
 *   recipients.csv  정규화된 공개용 수령자 목록 (같은 형식이므로 이 파일로 같은 root 재현 가능)
 *
 * 종료 코드: 0 성공, 1 입력 검증 실패, 2 사용법·파일 오류
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import {
  AirdropInputError,
  OUTPUT_FILES,
  buildAirdrop,
  formatFire,
  parseDenyList,
  parseFireAmount,
  parseRecipientsCsv,
  parseRound,
  sumAmounts,
  verifyAirdrop,
} from './lib/airdrop.mjs';

const TOOL_DIR = dirname(fileURLToPath(import.meta.url));

const USAGE = `사용법:
  node generate.mjs --input <recipients.csv> --out <출력 디렉터리> --expected-total <FIRE> [--round <n>] [--deny <주소,…>] [--force]

옵션:
  --input           수령자 CSV. 헤더 "address,amount", amount는 FIRE 단위 10진수(소수점 최대 18자리)
  --out             출력 디렉터리. forge 배포 스크립트가 읽을 수 있도록 airdrop/out/ 하위 권장 (예: out/round-1)
  --expected-total  CSV 합계와 정확히 같아야 하는 총량(FIRE). 예: 1차 20000000, 2차 30000000(+이월분)
  --round           회차 번호 (기본값 1)
  --deny            수령자가 될 수 없는 주소 (쉼표로 구분, 여러 번 지정 가능). FIRE 토큰·베스팅·이전 회차 분배 컨트랙트·
                    트레저리 Safe 등. 예약 대역(0x0000…FFFF 이하, 0x4200…0000~FFFF)은 이 옵션 없이도 항상 거부
  --force           기존 출력 파일 덮어쓰기 허용 (이미 공개한 회차는 덮어쓰지 마십시오)
  --help            도움말`;

class UsageError extends Error {}

function printErrors(title, errors) {
  console.error(`\n✖ ${title} (${errors.length}건)`);
  for (const error of errors) {
    const where = error.line !== undefined ? `${error.line}행 ` : '';
    console.error(`  - ${where}[${error.code}] ${error.message}`);
  }
  console.error('');
}

function main(argv) {
  let args;
  try {
    ({ values: args } = parseArgs({
      args: argv,
      strict: true,
      allowPositionals: false,
      options: {
        input: { type: 'string' },
        out: { type: 'string' },
        'expected-total': { type: 'string' },
        round: { type: 'string', default: '1' },
        deny: { type: 'string', multiple: true, default: [] },
        force: { type: 'boolean', default: false },
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
  for (const name of ['input', 'out', 'expected-total']) {
    if (args[name] === undefined || args[name] === '') throw new UsageError(`--${name} 옵션이 필요합니다`);
  }

  let expectedTotal;
  let round;
  let deny;
  try {
    expectedTotal = parseFireAmount(args['expected-total'], '--expected-total');
    round = parseRound(args.round);
    deny = parseDenyList(args.deny);
  } catch (error) {
    if (error instanceof AirdropInputError) throw new UsageError(error.message);
    throw error;
  }

  const inputPath = resolve(args.input);
  let csvText;
  try {
    csvText = readFileSync(inputPath, 'utf8');
  } catch (error) {
    throw new UsageError(`입력 파일을 읽을 수 없습니다: ${inputPath} (${error.code ?? error.message})`);
  }

  // 1) 행 단위 검증 (모든 오류를 행 번호와 함께 출력)
  const { entries, errors } = parseRecipientsCsv(csvText, { deny });
  if (errors.length > 0) {
    printErrors(`입력 검증 실패: ${inputPath}`, errors);
    return 1;
  }

  // 2) 합계 검증 (정확히 일치해야 함)
  const total = sumAmounts(entries);
  if (total !== expectedTotal) {
    const diff = total - expectedTotal;
    const sign = diff > 0n ? '+' : '-';
    const abs = diff > 0n ? diff : -diff;
    printErrors('합계 불일치', [
      {
        code: 'TOTAL_MISMATCH',
        message: `CSV 합계 ${formatFire(total)} FIRE ≠ --expected-total ${formatFire(expectedTotal)} FIRE (차이 ${sign}${formatFire(abs)} FIRE, 수령자 ${entries.length}명)`,
      },
    ]);
    return 1;
  }

  // 3) 트리 생성
  const { merkle, files } = buildAirdrop(entries, { round });

  // 4) 출력 (이미 있으면 --force 없이는 덮어쓰지 않음)
  const outDir = resolve(args.out);
  const existing = OUTPUT_FILES.filter((name) => existsSync(join(outDir, name)));
  if (existing.length > 0 && !args.force) {
    throw new UsageError(
      `출력 파일이 이미 있습니다: ${existing.map((name) => join(outDir, name)).join(', ')}\n` +
        '  이미 공개한 회차라면 덮어쓰지 말고 새 디렉터리를 쓰십시오. 덮어쓰려면 --force를 붙이십시오.',
    );
  }
  mkdirSync(outDir, { recursive: true });
  for (const name of OUTPUT_FILES) writeFileSync(join(outDir, name), files[name]);

  // 5) 디스크에 쓴 파일을 다시 읽어 전수 검증 (verify.mjs와 같은 검사)
  const check = verifyAirdrop({
    treeData: JSON.parse(readFileSync(join(outDir, 'tree.json'), 'utf8')),
    merkleData: JSON.parse(readFileSync(join(outDir, 'merkle.json'), 'utf8')),
    recipientsText: readFileSync(join(outDir, 'recipients.csv'), 'utf8'),
    expectedTotal,
    expectedRound: round,
    deny,
  });
  if (check.errors.length > 0) {
    printErrors('생성 결과 자체 검증 실패 (버그 가능성 — 출력물을 사용하지 마십시오)', check.errors);
    return 1;
  }

  const forgeReadable = resolve(TOOL_DIR, 'out');
  const relToForgeDir = relative(forgeReadable, outDir);
  const insideForgeDir = relToForgeDir === '' || (!relToForgeDir.startsWith('..') && !relToForgeDir.startsWith(sep));
  const merklePathForForge = relative(resolve(TOOL_DIR, '..'), join(outDir, 'merkle.json'));

  console.log(`FIRE 에어드롭 Merkle 생성 완료 (전수 검증 통과)
  회차 (round)        : ${merkle.round}
  수령자 수 (count)   : ${merkle.count}
  총량 (totalFire)    : ${merkle.totalFire} FIRE
  총량 (total, wei)   : ${merkle.total}
  Merkle Root         : ${merkle.root}
  출력 디렉터리       : ${outDir}
                        tree.json, merkle.json, recipients.csv

다음 단계:
  1. node verify.mjs --dir ${args.out} --expected-total ${args['expected-total']} --round ${merkle.round}${deny.size > 0 ? ` --deny ${[...deny].join(',')}` : ''}
  2. recipients.csv · tree.json · merkle.json과 Merkle Root를 GitHub에 먼저 공개
     (git add 후 git status로 세 파일이 포함됐는지 확인, 커밋 해시 기록. merkle.json은 재포맷하지 말 것:
      배포 스크립트가 generate.mjs 형식의 첫 7줄만 읽음)
  3. Base Sepolia 리허설 후 에어드롭 지갑으로 배포 (프로젝트 루트에서, 자세한 절차는 airdrop/README.md 6절):
     export AIRDROP_MERKLE_JSON=${merklePathForForge} AIRDROP_EXPECTED_ROOT=${merkle.root}
     export AIRDROP_WALLET=<에어드롭 지갑>
     # FIRE_TOKEN: 비우면 deployments/<chainId>.json 기록값 (메인넷은 기록 필수). 기록이 없으면 FIRE_TOKEN=<배포된 FIRE>
     # 메인넷(--rpc-url base)은 아래 두 명령 모두 앞에 CONFIRM_MAINNET=I_UNDERSTAND
     # 1) 시뮬레이션 (전송 없음, 로그·경고 확인)
     forge script script/DeployAirdrop.s.sol:DeployAirdrop --rpc-url <base|base_sepolia> --ledger --sender $AIRDROP_WALLET
     # 2) 전송 (배포 성공 영수증을 확인한 뒤에만 예치)
     forge script script/DeployAirdrop.s.sol:DeployAirdrop --rpc-url <base|base_sepolia> --ledger --sender $AIRDROP_WALLET --broadcast --slow`);
  if (!insideForgeDir) {
    console.warn(`
⚠ 출력 디렉터리가 airdrop/out/ 밖입니다. forge 배포 스크립트는 foundry.toml fs_permissions에 따라
  ./airdrop/out 과 ./test/fixtures 만 읽을 수 있습니다.`);
  }
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
