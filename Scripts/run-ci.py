#!/usr/bin/env python3
"""CI 의 `run:` 블록을 로컬에서 그대로 돌린다.

밀기 전에 여기서 먼저 보라고 있는 것이다. `actions/*` 스텝과 러너에만 있는 것은 건너뛴다.
"""

import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP = {"Show toolchain", "Build universal artifacts", "Check the artifacts actually work"}
# `run:` 이 없는 스텝. 누락 검사에서 제외한다.
USES_ONLY: set[str] = set()


def steps(text):
    """`- name: X` 와 그 뒤 `run:` 을 뽑는다.

    블록(`run: |`)과 한 줄(`run: swift build`) 둘 다 읽는다. 한 줄짜리를 빠뜨리면
    `swift build`·`swift test` 가 통째로 빠지고, 남은 통합 검사는 예전에 만들어 둔
    바이너리로 통과해 버린다 — 아무것도 안 고쳤는데 초록이 나온다.
    """
    out = []
    lines = text.split("\n")
    index = 0
    while index < len(lines):
        match = re.match(r"      - name: (.+)", lines[index])
        if not match:
            index += 1
            continue
        name = match.group(1).strip()
        index += 1

        while index < len(lines) and not re.match(r"      - name:", lines[index]):
            block = re.match(r"\s+run: \|", lines[index])
            single = re.match(r"\s+run: (\S.*)$", lines[index])

            if block:
                index += 1
                body = []
                while index < len(lines):
                    line = lines[index]
                    if line.strip() and not line.startswith("          "):
                        break
                    body.append(line[10:] if len(line) > 10 else "")
                    index += 1
                out.append((name, "\n".join(body)))
                break
            if single:
                out.append((name, single.group(1).strip()))
                index += 1
                break
            index += 1
    return out


def tracked_state():
    """git 이 보는 현재 상태. 실행이 남긴 것만 가려내는 데 쓴다."""
    result = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=REPO, capture_output=True, text=True)
    return set(result.stdout.strip().split("\n")) - {""}


def main():
    text = open(f"{REPO}/.github/workflows/ci.yml").read()
    # 러너의 HOME 은 비어 있다. 내 로그인 상태가 auth 검사를 통과시키면 안 된다.
    home = tempfile.mkdtemp()
    environment = dict(os.environ, GITHUB_WORKSPACE=REPO, HOME=home)
    failed = []
    before = tracked_state()

    # 파싱이 스텝을 조용히 빠뜨리면 "실패 없음" 이 거짓말이 된다 — 한 줄 `run:` 을 못 읽어
    # `swift build` 와 `swift test` 가 통째로 빠진 적이 있다.
    found = {name for name, _ in steps(text)}
    declared = set(re.findall(r"^      - name: (.+)$", text, re.M))
    # `uses:` 스텝은 run 이 없으니 셀 수 없다. 이름으로 걸러 낸다.
    missing = {n.strip() for n in declared} - found - USES_ONLY
    if missing:
        print("⚠️ 워크플로에 있는데 읽지 못한 스텝:", ", ".join(sorted(missing)))
        failed.append("(스텝 누락)")

    for name, body in steps(text):
        if name in SKIP:
            print(f"  ·  {name} (건너뜀)")
            continue
        result = subprocess.run(
            ["bash", "-c", body], cwd=REPO, env=environment,
            capture_output=True, text=True)
        if result.returncode == 0:
            print(f"  ✅ {name}")
        else:
            print(f"  ❌ {name} (종료 {result.returncode})")
            tail = (result.stdout + result.stderr).strip().split("\n")[-6:]
            for line in tail:
                print(f"        {line}")
            failed.append(name)

    # 검사 파일이 저장소에 남으면 다음 `git add -A` 에 딸려 들어간다.
    # 이미 있던 변경과 섞이지 않게 실행 전후를 비교한다.
    left = tracked_state() - before
    if left:
        print()
        print("⚠️ CI 가 저장소에 파일을 남겼습니다:")
        for line in sorted(left):
            print("   ", line)
        failed.append("(트리 오염)")

    print()
    print("실패:", ", ".join(failed) if failed else "없음")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
