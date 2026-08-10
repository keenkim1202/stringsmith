"""머리글 구분선이 없는 표 조각을 찾는다.

편집이 표 중간에 끼어들면 뒷부분이 머리글 없는 조각으로 떨어져 나간다. 실제로 옵션 표가
그렇게 갈라진 적이 있고, 렌더링하면 표가 아니라 파이프 문자 줄로 보인다.
"""
import re
import sys

SEPARATOR = re.compile(r"^\|[\s:|-]+\|$")

def broken_tables(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    in_code = False
    bad = []
    previous_was_table = False
    for number, line in enumerate(lines, 1):
        if line.startswith("```"):
            in_code = not in_code
            previous_was_table = False
            continue
        if in_code:
            continue
        is_row = line.startswith("|")
        if is_row and not previous_was_table:
            # 표의 첫 줄이면 다음 줄이 구분선이어야 한다.
            following = lines[number] if number < len(lines) else ""
            if not SEPARATOR.match(following):
                bad.append((number, line))
        previous_was_table = is_row
    return bad

failed = False
for path in sys.argv[1:]:
    for number, line in broken_tables(path):
        print(f"{path}:{number}: 머리글 구분선이 없는 표: {line[:60]}")
        failed = True
sys.exit(1 if failed else 0)
