# stringsmith

**스프레드시트에서 iOS 로컬라이제이션 파일을 만듭니다.**

[English](README.md) · 한국어

번역은 Google Sheets·Excel로 관리됩니다. Apple이 의도한 XLIFF 워크플로는 번역 벤더용 기계
포맷이라 기획자·디자이너가 쓸 수 없기 때문입니다. 그런데 시트에서 `.xcstrings`까지 가는
다리는 대개 검증도 왕복도 확인 수단도 없는 사내 스크립트입니다.

stringsmith는 그 다리를 제품으로 만듭니다.

```bash
ss init        # 시트를 읽어 설정 초안 생성
ss generate    # .xcstrings + 타입세이프 Swift 접근자 생성
ss preview     # 번역 확인 앱 실행
```

`ss`는 `stringsmith` 명령의 짧은 별칭입니다. 둘은 완전히 같으며, 아래 설치 과정에서 함께 만들어집니다.

## 설치

### 내려받기

[Releases](https://github.com/keenkim1202/stringsmith/releases)에서 최신 버전을 받으세요.
Intel · Apple Silicon 유니버설 바이너리이고 macOS 13 이상이 필요합니다.

| 파일 | 내용 |
|---|---|
| `StringsmithPreview-macOS.zip` | 번역 확인 앱 |
| `stringsmith-macOS.tar.gz` | CLI |

```bash
# 앱 — 압축을 풀어 ~/Applications 에 넣은 뒤
xattr -dr com.apple.quarantine ~/Applications/StringsmithPreview.app

# CLI
tar -xzf stringsmith-macOS.tar.gz
sudo mv stringsmith /usr/local/bin/ && sudo ln -sf /usr/local/bin/stringsmith /usr/local/bin/ss
xattr -dr com.apple.quarantine /usr/local/bin/stringsmith
```

> ⚠️ **서명되지 않은 빌드**라 처음 열 때 macOS가 막습니다. 위 `xattr` 한 줄로 격리 속성을
> 지우면 열립니다. 코드 서명은 유료 Apple Developer 계정이 필요해 아직 하지 않았습니다.

### 소스에서 빌드

```bash
git clone https://github.com/keenkim1202/stringsmith && cd stringsmith
make install        # CLI → /usr/local/bin/stringsmith (별칭 ss)
make install-app    # 앱  → ~/Applications/StringsmithPreview.app
```

`PREFIX=~/.local`, `APPDIR=/Applications`로 위치를 바꿀 수 있습니다. `xattr`도 필요 없습니다.

예제 시트가 두 개 들어 있습니다. `Examples/sample-sheet.csv`(간단한 둘러보기)와
`Examples/edge-cases.csv`(파서·변수·코드 생성의 까다로운 경우 — CI가 결과를 검사합니다).

## Google Sheets 에서 읽기

```bash
ss init --url "https://docs.google.com/spreadsheets/d/{ID}/edit#gid=0"
ss generate
```

실행할 때마다 시트를 가져오므로 CSV를 손으로 다시 받을 필요가 없습니다. URL의 `gid`가 탭을
가리키고, 설정의 `"gid"` 로 덮어쓸 수 있습니다.

마지막으로 성공한 응답은 `.stringsmith/cache/` 에 남습니다. 네트워크가 안 되면 캐시로 진행하며
경고를 냅니다 — 오프라인이라고 빌드가 멈추면 곤란하니까요.

### 여러 탭

화면·도메인별로 나눠 둔 탭을 하나로 이어 붙일 수 있습니다:

```json
{ "source": { "tabs": ["common", "checkout", "settings"] } }
```

적은 순서대로 읽어 위에서 아래로 쌓습니다. 헤더는 첫 탭 것을 쓰고 나머지는 그와 같아야
합니다 — 컬럼이 다른 채로 이어 붙이면 값이 조용히 엉뚱한 열로 들어가므로, 그럴 땐 멈춥니다.
빈 탭은 건너뜁니다. 아직 안 채운 탭이 섞여 있는 건 흔한 일이니까요.

탭 이름은 로그인했을 때만 쓸 수 있습니다 — 이름을 탭으로 바꾸려면 API 가 필요합니다.
로그인하지 않으면 `gid` 를 적습니다.

> 오류는 그 행이 있던 **탭까지 함께** 짚습니다 — `102` 가 아니라 `errors!2` 입니다. 병합본의
> 102행은 두 번째 탭의 2행이고, 찾아갈 수 있는 건 뒤쪽 표기뿐입니다.

### 비공개 시트

공개 공유가 아닌 시트는 로그인이 필요합니다:

```bash
ss auth login       # 브라우저가 한 번 열립니다
ss generate         # 이제 Sheets API 로 읽습니다
ss auth status      # 또는: ss auth logout
```

로그인하면 **내 Google 계정으로 열 수 있는 시트**는 전부 읽힙니다 — 공유 설정을 풀지 않아도
됩니다. 로그인하지 않으면 지금처럼 공개 내보내기를 쓰므로, 공개 시트는 설정할 게 없습니다.

로그인은 PKCE 를 쓰고 `spreadsheets.readonly` 범위 하나만 요구합니다. refresh token 은
`~/.config/stringsmith/credentials.json` 에 권한 `600` 으로 저장됩니다. `ss auth logout` 이
파일을 지우고, Google 쪽 접근 권한까지 끊으려면
[myaccount.google.com/permissions](https://myaccount.google.com/permissions) 에서 해제합니다.

### OAuth 클라이언트 설정 (최초 1회, 5분)

**stringsmith 는 Google 클라이언트를 내장하지 않습니다. 의도한 것입니다.** 내장하려면
비밀값을 이 저장소에 공개해야 합니다. 직접 등록하면 미검증 앱 경고도, 공용 사용자 한도도
없습니다.

1. [console.cloud.google.com](https://console.cloud.google.com) → 프로젝트 만들기
2. **API 및 서비스 → 라이브러리** → **Google Sheets API** 사용 설정
   *(Drive 는 켜지 마세요 — "제한" 등급이라 보안 심사가 붙습니다)*
3. **OAuth 동의 화면** → 사용자 유형 **외부** → 범위에
   `.../auth/spreadsheets.readonly` 추가 → **테스트 사용자**에 본인 주소 추가
4. **사용자 인증 정보 → 사용자 인증 정보 만들기 → OAuth 클라이언트 ID** →
   애플리케이션 유형 **데스크톱 앱**
5. stringsmith 가 찾는 자리에 저장:

```bash
ss auth setup       # 값이 비어 있는 ~/.config/stringsmith/client.json 을 만듭니다
```

   그 뒤 `client_id` 와 `client_secret` 을 채웁니다. Console 이 내려 주는 JSON 을 그
   파일에 그대로 덮어쓰면 타이핑할 것도 없습니다.

Google 이 씌우는 `installed` 껍데기까지 읽으므로 벗길 필요가 없습니다. 필요한 건 두
필드뿐입니다 — [`Examples/google-client.example.json`](Examples/google-client.example.json)
참고:

```json
{ "client_id": "….apps.googleusercontent.com", "client_secret": "…" }
```

환경 변수가 파일보다 우선합니다. CI 에서 쓸모 있습니다:

```bash
export STRINGSMITH_GOOGLE_CLIENT_ID=…apps.googleusercontent.com
export STRINGSMITH_GOOGLE_CLIENT_SECRET=…
```

클라이언트가 없으면 `ss auth login` 이 같은 절차를 그대로 출력합니다.

> **"데스크톱 앱" 이어야 합니다.** 이 방식이 필요로 하는 `127.0.0.1` 리다이렉트를 받는 유형은
> 그것뿐입니다. 함께 발급되는 비밀값도 **반드시 필요합니다** — PKCE 를 써도 Google 이 비밀값
> 없이는 토큰 교환을 거부합니다. 파일은 본인만 보도록 `chmod 600` 해 두세요.

## 시트 형태

| 키 | 화면 | 설명 | 한국어 | 영어 |
|---|---|---|---|---|
| `settings.title` | 설정 | 화면 상단 제목 | 설정 | Settings |
| `cart.itemCount` | 장바구니 | 이름과 개수 | `{name}님의 상품 {count}개` | `{count} items for {name}` |

컬럼명은 팀마다 다르므로 **매핑으로 지정**합니다. `init`이 헤더를 읽어 초안을 만들어줍니다.

- **필수:** 키 컬럼 + 언어 컬럼 1개 이상
- **선택:** 화면(네임스페이스·주석), 설명(주석)
- 따옴표 안의 쉼표·개행, CRLF, BOM, 빈 행, 첫 행이 아닌 헤더를 처리합니다

> 번역 값의 앞뒤 공백은 그대로 둡니다. `"{name} "` 처럼 뒤에 공백을 두는 문구가 실제로
> 있고, 지워 버리면 시트에서 표현할 방법이 없습니다. 다만 **공백만 있는 칸은 미번역**으로
> 봅니다 — 그러지 않으면 빠진 번역이 경고 없이 지나갑니다. 키·화면·설명은 계속 다듬습니다.
> 거기 붙은 공백은 실수입니다.

## 생성되는 것

| 산출물 | 결과 |
|---|---|
| `xcstrings` | `Localizable.xcstrings` — String Catalog |
| `swift` | `L10n.swift` — 타입세이프 접근자 |

```swift
Text(L10n.Cart.itemCount("민수", "3"))
Text(L10n.Settings.title)
```

네임스페이스는 키 앞머리에서 옵니다 (`order_cancel_confirm_body` → `L10n.Order.cancelConfirmBody`).
Swift 예약어는 백틱으로 감싸고, 이름이 겹치면 접미사를 붙인 뒤 보고합니다.

> Apple의 `xcstringstool generate-symbols`도 접근자를 만듭니다. 그것으로 충분하면 그쪽을
> 쓰세요. stringsmith는 네임스페이스가 계층이고, `String`을 반환하며(iOS 16 미만에서도 동작),
> 원문 값과 설명을 doc 주석에 넣는다는 점이 다릅니다.

## 변수

시트의 변수 표기를 iOS 포맷 지정자로 바꿉니다. **원문 로케일이 위치 번호를 정하고, 번역은
이름으로 그 번호를 찾아갑니다** — 어순이 달라도 지정자가 맞게 붙습니다.

| 시트 | 생성 결과 |
|---|---|
| `{name}님의 상품 {count}개` (ko, 원문) | `%1$@님의 상품 %2$@개` |
| `{count} items for {name}` (en) | `%2$@ items for %1$@` ← 자동으로 뒤집힘 |

번역가는 `%1$`·`%2$`를 몰라도 됩니다. 번역가가 가장 자주 깨뜨리는 부분입니다.

- 인식하는 표기: `{name}`(권장), `%@`/`%d`/`%1$@`, `<count/>`(기본 꺼짐). 한 시트에 섞여 있어도 됩니다
- **변수 자리는 항상 `String`(`%@`)입니다.** 시트는 타입을 알려주지 못하고, 틀린 타입은 런타임에
  값을 조용히 깨뜨리는 반면 `%@`는 어떤 값이든 받습니다
- 중괄호가 몇 겹이든 **안쪽 쌍이 변수**입니다. 리터럴 중괄호는 여는 쪽 바로 앞에 백슬래시를
  붙입니다 — `\{count}` → `{count}`
- `\n`·`\t`는 실제 제어 문자가 됩니다. `.xcstrings`는 JSON이라 두 글자로 두면 화면에 `\n`이 보입니다.
  단어 중간이어도 마찬가지라 `C:\notes`는 줄바꿈 + `otes`가 됩니다. 그 외 자리의 백슬래시는 평범한 문자입니다
- `"50% off"`는 변수가 아닙니다 (`% o`는 printf 문법상 유효하지만 로컬라이제이션 문자열에
  그런 용법이 없습니다)

변환 내역은 출력이 터미널일 때 빨강·초록 diff 로 표시됩니다. `NO_COLOR` 로 끄고,
`FORCE_COLOR` 로 파이프에서도 켤 수 있습니다.

쓰기 전에 검증합니다 — 번역에서 누락된 변수, 원문에 없는 변수, 어순 변화를 못 따라가는 이름 없는
지정자. **바꾼 내용은 항상 출력**하고, `-n`으로 파일을 건드리기 전에 볼 수 있습니다.

## 번역 확인 앱

시트를 직접 읽는 독립 macOS 앱입니다. `generate`를 먼저 돌릴 필요가 없습니다.

```bash
ss preview     # 현재 프로젝트를 앱에서 엽니다
```

- **여러 프로젝트를 탭으로.** 다른 프로젝트에서 `ss preview`를 실행하면 같은 창에 탭이 늘어납니다.
  탭을 더블클릭하면 이름 변경, 끌면 순서 변경
- **갱신**(⟳ / ⌘R) — 시트를 고친 뒤 다시 읽습니다
- 모든 언어를 **나란히** 보여줍니다. 검수는 비교 작업이니까요. 언어 칩을 끌어 순서를 바꿉니다
- **변수 자리에 색**이 들어가고, 예시 값을 넣어볼 수 있습니다. 입력 칸 라벨은 `arg1`이 아니라
  원본 이름(`name`·`count`)입니다
- 토글: *원본 표기*(치환 전 `{name}` 확인) · *변수 있는 것만* · *번역 누락만*
- 섹션 탭을 누르면 그 위치로 이동합니다. 창 고정은 Window ▸ 항상 맨 앞 (⇧⌘T)
- 앱 UI 자체가 시스템 언어를 따라갑니다 (en · ko · ja)

## 명령어

```bash
ss init [시트]        # 시트 헤더를 읽어 .stringsmith.json 초안 생성
ss generate           # 산출물 생성
ss preview            # 확인 앱에서 열기
```

모든 명령은 `stringsmith`로 풀어 써도 똑같이 동작합니다. `ss`는 같은 바이너리를 가리키는 심볼릭 링크라
`ss generate`와 `stringsmith generate`는 완전히 같습니다. `generate`는 `build`·`g`로도 부를 수 있습니다.
전체 목록은 `stringsmith --help`에 있습니다.

`init`은 시트(폴더에 CSV/TSV가 정확히 하나면), 헤더 행, 원문 로케일을 스스로 찾습니다.
`.stringsmith.json`은 현재 디렉터리부터 위로 올라가며 찾습니다 (git과 같은 방식).

| 옵션 | 명령 | 뜻 |
|---|---|---|
| `-o` `--output` | init | 산출물 디렉터리 (기본 `Resources`) |
| `--url` | init | Google Sheets 공유 URL |

### `ss validate`

파일을 만들지 않고 시트만 검사합니다. `generate` 와 같은 규칙을 쓰되 산출물은 남기지
않습니다 — 시트를 고치는 사람은 "이대로 넘겨도 되나" 만 알면 되고, 그걸 확인하자고 남의
작업 디렉터리에 파일을 만들 이유가 없습니다.

| 플래그 | 뜻 |
|---|---|
| `-v` `--verbose` | 변수 변환과, 경고에 딸린 항목을 모두 나열합니다 |
| `--strict` | 경고만 있어도 실패로 처리합니다 |

경고는 그 원인이 된 키와 행을 함께 짚습니다. 건수만으로는 어디를 봐야 할지 알 수 없으니까요:

```
  ⚠️ ja: 3/100 translations missing
       missing.ja_only (row 98)
       missing.both (row 100)
       missing.whitespace_only (row 101)
```

기본은 5건까지 보여주고 나머지는 `-v` 로 봅니다. `generate` 도 같은 내용을 냅니다.

경고는 기본적으로 실패가 아닙니다. 아직 채우는 중인 시트에서 번역 누락은 정상적인 상태니까요.
`--strict` 는 그렇지 않을 수 있는 CI 용입니다.

### 무엇이 생성을 막는가

| 문제 | 기본 |
|---|---|
| 시트에 같은 키가 두 번 | 에러 |
| 원문 값이 비어 있음 | 에러 |
| 원문에 없는 변수가 번역에 있음 | 에러 |
| **두 키가 같은 Swift 이름이 됨** | **에러** |
| 번역 값이 비어 있음 | 경고 |

아래 둘은 설정으로 바꿉니다:

```json
{ "validation": { "failOn": ["collision", "missing"] } }
```

이름 충돌을 기본으로 막는 건 **나중에는 피해가 보이지 않기 때문**입니다. 두 키가
`helloWorld` 와 `helloWorld2` 가 되는데 코드 어디에도 어느 쪽이 어느 키인지 없고, 나중에
시트에서 키 하나를 지우면 남은 키의 이름이 바뀌어 코드가 조용히 다른 문자열을 가리킵니다.

번역 누락은 막지 않습니다. 아직 채우는 중인 시트에는 늘 빈 칸이 있고, 이걸로 막으면 번역이
끝나기 전에는 빌드를 할 수 없습니다. iOS 는 번역이 없으면 원문으로 대체하기도 합니다. CI 에서
조이려면 `"missing"` 을 넣거나, 설정을 건드리지 않고 `ss validate --strict` 를 씁니다.

### `ss auth setup` · `login` · `logout` · `status`

`setup` 은 채워 넣을 클라이언트 파일을 만들고, `login` 은 Google 에 로그인합니다.
| `-r` `--header-row` | init | 헤더 행 번호 (1부터) |
| `-s` `--source-locale` | init | 원문 로케일 |
| `--artifacts` | init | `xcstrings` · `swift` |
| `-f` `--force` | init | 기존 설정 덮어쓰기 |
| `-c` `--config` | 전부 | 설정 파일 경로 |
| `-n` `--dry-run` | generate | 무엇이 바뀔지만 보여주고 쓰지 않음 |
| `-v` `--verbose` | generate | 변수 변환 내역 전체 출력 |
| `--only` | generate | 이번 실행만 산출물 지정 |

## 설정

```json
{
  "source":  { "path": "strings.csv", "headerRow": 2, "defaultLocale": "ko" },
  "columns": {
    "key": "키", "screen": "화면", "description": "설명",
    "languages": { "ko": "한국어", "en": "영어", "ja": "일본어" }
  },
  "output": {
    "path": "Sources/Resources",
    "artifacts": ["xcstrings", "swift"],
    "tableName": "Localizable",
    "swift": { "enumName": "L10n", "namespace": "keyPrefix", "bundle": "main" }
  },
  "placeholders": { "syntax": ["apple", "brace"], "positional": "auto" }
}
```

경로는 **설정 파일 위치 기준**이라 저장소 어디서 실행해도 같게 동작합니다.

| 키 | 값 |
|---|---|
| `source.type` | `csv` · `google-sheets` |
| `output.swift.namespace` | `keyPrefix` · `screen` · `none` |
| `output.swift.bundle` | `main` · `module` (SPM 리소스) |
| `placeholders.syntax` | `apple` · `brace` · `xml` |
| `placeholders.positional` | `auto` (2개 이상일 때만 위치 지정자) · `always` · `never` |
| `placeholders.braceOpen` / `braceClose` / `escape` | 구분자, 기본 `{` `}` `\` |

## 설계상의 선택

- **출력이 결정적입니다.** 같은 입력이면 바이트가 같습니다. 생성물이 커밋되는 이상 비결정적
  출력은 매 실행마다 머지 충돌을 만듭니다. 내용이 같으면 다시 쓰지 않아 불필요한 재빌드도 막습니다
- **빈 번역은 넣지 않습니다.** `translated`로 넣으면 Xcode에서 누락이 감춰집니다
- **`extractionState`는 `manual`** — 그래야 Xcode 자동 추출이 시트에서 온 키를 stale로 지우지 않습니다
- **파일 내부 검증은 다른 도구에 맡깁니다.** [LocaleLint](https://forums.swift.org/t/localelint-ci-validation-for-ios-localization-files-string-catalogs-xliff/86939)·[Locheck](https://github.com/irskep/locheck)가
  `.xcstrings` 안쪽을 잘 봅니다. stringsmith는 **시트 쪽**을 검증합니다. 함께 쓰세요

## 개발

```
StringsmithCore      라이브러리 — 파싱·매핑·검증·생성. 자료구조만 반환하고 출력하지 않는다
stringsmith          CLI — 얇은 래퍼 (인자 파싱 + 리포팅)
StringsmithPreview   확인 앱 — 코어를 링크해 시트를 직접 읽는다
```

```bash
make test       # 102개 테스트
make release    # 배포용 유니버설 묶음 → .build/dist
```

CI가 푸시·PR마다 테스트와 end-to-end 검증(생성 → Apple 도구가 받아들이는지 → 접근자 컴파일 →
재실행 시 무변경)을 돌립니다. `v*` 태그를 밀면 릴리스가 만들어집니다.

## 라이선스

아래 둘 중 하나를 **골라서** 쓰면 됩니다.

- [Apache License 2.0](LICENSE-APACHE)
- [MIT license](LICENSE-MIT)

MIT는 짧고 익숙하며, Apache-2.0은 명시적 특허 허여가 있어 이를 요구하는 조직에서 유리합니다.
따로 밝히지 않는 한, 기여하신 내용도 같은 방식으로 이중 라이선스가 적용됩니다.
