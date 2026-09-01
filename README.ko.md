# stringsmith

**스프레드시트에서 iOS 로컬라이제이션 파일을 만듭니다.**

[English](README.md) · 한국어 · [변경 이력](CHANGELOG.ko.md)

번역은 Google Sheets·Excel로 관리됩니다. Apple이 의도한 XLIFF 워크플로는 번역 벤더용 기계
포맷이라 기획자·디자이너가 쓸 수 없기 때문입니다. 그런데 시트에서 `.xcstrings`까지 가는
다리는 대개 검증도 왕복도 확인 수단도 없는 사내 스크립트입니다.

stringsmith는 그 다리를 제품으로 만듭니다.

## 무엇이 되는가

시트의 한 행이:

| key | screen | ko | en |
|---|---|---|---|
| `cart.greeting` | 장바구니 | `{name}님의 장바구니` | `{name}'s cart` |

String Catalog 항목과 이것이 됩니다:

```swift
Text(L10n.Cart.greeting(customer))
```

인자가 있는 건 시트가 그렇게 적혀 있기 때문입니다. 시트에서 `{name}` 을 빼면 호출부가
컴파일되지 않습니다 — 그게 이 도구의 요점입니다.

## 설치

```bash
brew install keenkim1202/tap/stringsmith
```

CLI 입니다. `stringsmith` 와 짧은 이름 `ss` 가 함께 깔립니다. 유니버설 바이너리, macOS 13+.

확인 앱은 별도 파일이고 `ss preview` 를 쓸 때만 필요합니다.
[Releases](https://github.com/keenkim1202/stringsmith/releases) 에서
`StringsmithPreview-macOS.zip` 을 받으세요:

```bash
unzip StringsmithPreview-macOS.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/StringsmithPreview.app
```

서명되지 않은 앱이라서 `xattr` 줄이 필요합니다.

Homebrew 없이 받으실 경우, 같은 페이지에서 `stringsmith-macOS.tar.gz` 를 받습니다:

```bash
tar -xzf stringsmith-macOS.tar.gz
sudo mv stringsmith /usr/local/bin/ && sudo ln -sf /usr/local/bin/stringsmith /usr/local/bin/ss
xattr -dr com.apple.quarantine /usr/local/bin/stringsmith
```

소스에서 빌드하려면 `make install`(CLI) 과 `make install-app`(확인 앱). `xattr` 이 필요 없습니다.

## 사용

```bash
ss init        # 시트 헤더에서 .stringsmith.json 생성
ss generate    # 산출물 생성
```

`init` 이 시트와 헤더 행, 원문 언어를 알아서 찾습니다. 만들어진 설정을 확인한 뒤 생성하면
됩니다. `.stringsmith.json` 은 git 처럼 현재 디렉터리에서 위로 올라가며 찾습니다.

| 커맨드 | |
|---|---|
| `ss init [시트]` | 설정 초안. Google Sheets 는 `--url`, 출력 형식은 `--format` |
| `ss import <경로>` | 이미 있는 `.xcstrings`·`.lproj` 파일에서 시트 만들기 |
| `ss generate` | 산출물 생성. `-n` 은 미리보기, `--only` 는 골라 만들기 |
| `ss validate` | 파일을 만들지 않고 시트만 검사. CI 는 `--strict` |
| `ss drift` | 시트와 코드가 어긋난 키 찾기 |
| `ss preview` | 확인 앱 열기 |
| `ss auth login` | 비공개 시트를 위한 Google 로그인 |

플래그 전체는 `--help` 가 보여 줍니다. `ss` 와 `stringsmith` 는 같은 바이너리입니다.

### 이미 파일이 있다면

나머지 명령은 전부 시트가 있다고 가정합니다. 번역이 아직 `.xcstrings` 나 `.lproj` 에 있다면
`import` 가 그 자리를 메웁니다.

```bash
ss import Sources/Resources        # 또는 path/to/Localizable.xcstrings
ss init strings.csv
```

키마다 한 행, 언어마다 한 열이 되고 `/* 주석 */` 은 `description` 열로 옮겨집니다.
복수형은 키 접미사(`cart.items.one`)로 들어갑니다. 시트가 복수형을 적는 방식입니다.

변수는 `{arg1}`, `{arg2}` 로 돌아옵니다. 파일에는 변수의 자리만 있고 그것이 무엇이었는지는
남아 있지 않으니, generate 전에 시트에서 이름을 고치세요. 복수형에서 수를 세는 변수만은
`count` 라는 이름을 유지합니다. `.stringsdict` 는 그 자리에서 정수를 봐야 범주를 고를 수
있기 때문입니다.

## 소스

CSV·TSV·`.xlsx` 를 파일에서 읽습니다. 경로를 주거나 `init` 이 찾게 두면 됩니다. 엑셀에
추가 의존성은 없습니다. 숫자 서식은 해석하지 않으므로 날짜 서식이 걸린 칸은 일련번호로 읽힙니다.

Google Sheets 는 공유 URL 로 읽습니다:

```bash
ss init --url "https://docs.google.com/spreadsheets/d/{ID}/edit#gid=0"
```

공개 링크는 그대로 됩니다. 로그인이 필요한 시트라면 `ss auth setup` 을 실행하세요 — OAuth
클라이언트 파일을 만들고 콘솔에서 할 다섯 단계를 출력합니다 — 그 뒤 `ss auth login`.
로그인하면 내 계정으로 열 수 있는 시트는 공유 설정을 바꾸지 않아도 읽힙니다. 마지막으로 성공한
응답을 캐시하므로 — 로그인 여부와 무관하게, 이어 붙인 탭까지 — 오프라인이라고 빌드가 멈추지
않습니다. 시트가 **읽히지 않게** 된 것은 다른 문제라 그대로 실패합니다. 캐시로 덮으면 몇 달째
모르고 지나갑니다.

탭으로 나뉜 시트는 `"tabs": ["common", "checkout"]` 으로 이어 붙입니다. 이름은 로그인해야
쓸 수 있습니다 — 이름을 탭으로 바꾸려면 API 가 필요합니다. 공개 링크로는 gid 를 적습니다.

## 산출물

형식은 하나만 고릅니다. 둘은 택일이지 한 쌍이 아닙니다.

| | |
|---|---|
| `xcstrings` (기본) | `Localizable.xcstrings` 하나에 모든 언어 |
| `strings` | `<locale>.lproj/Localizable.strings`, 복수형은 `.stringsdict` |

```bash
ss generate --format strings
```

타입 안전 Swift 접근자는 어느 쪽이든 함께 만들어집니다. **SwiftPM 은 String Catalog 를
컴파일하지 않습니다** — Swift 패키지는 `strings` 로 내보내야 하고, Xcode 프로젝트의 앱 타깃은
둘 다 됩니다.

### 변수

시트에 `{name}` 이라고 씁니다. `%@` 가 되고, 둘 이상이면 `%1$@` 이 되어 번역에서 어순이
바뀌어도 따라갑니다. `\{name}` 은 글자 그대로의 중괄호이고, 변수 옆의 `%` 는 알아서
이스케이프됩니다.

**모든 자리는 `String`** 입니다. 시트로는 값의 타입을 알 수 없고, 틀린 타입은 런타임에
조용히 값을 깨뜨리는 반면 `%@` 는 무엇이든 받습니다.

### 복수형

키 접미사로 씁니다 — `cart.items.one`·`cart.items.other`, CLDR 범주를 그대로 씁니다. 두 형식
모두 제대로 담고, 접근자는 `Int` 를 받는 함수 하나입니다: `L10n.Cart.items(3)`. 어느 형태를
쓸지는 호출부가 아니라 iOS 가 정할 일입니다.

## 검사

`generate` 는 잘못된 결과가 나올 것에서 멈춥니다 — 중복 키, 빈 원문 값, 원문에 없는 변수,
두 키가 같은 Swift 이름이 되는 경우. 나머지는 경고로 내되 키와 행을 짚습니다.

```
⚠️ ja: 3/100 translations missing
     missing.ja_only (row 98)
```

어떤 경고에서 멈출지는 `validation.failOn` 이 정합니다. 번역 누락은 일부러 막지 않습니다 —
아직 채우는 중인 시트에는 늘 빈 칸이 있으니까요.

`ss drift` 는 컴파일이 못 잡는 것을 봅니다 — 아무도 안 쓰는 키와, 문자열로
(`NSLocalizedString`) 부르는데 시트에 없는 키.

### CI

`validate` 는 시트를 검사하고, `git diff` 는 시트만 고치고 생성물을 다시 만들지 않은 PR 을
잡습니다. 생성 파일을 커밋하므로 둘은 같은 잡에 들어갑니다.

```yaml
- run: ss validate --strict
- run: ss generate
- run: git diff --exit-code    # 시트만 고치고 산출물은 안 올린 경우
```

실패는 종료 코드로 구분되므로 스크립트가 분기할 수 있습니다.

| | |
|---|---|
| `0` | 통과 |
| `2` | 설정이나 시트를 읽지 못했습니다. 설정을 고쳐야 합니다. |
| `3` | 시트는 읽었지만 내용이 검증을 통과하지 못했습니다. 시트를 고쳐야 합니다. |
| `64` | 명령이나 플래그가 잘못됐습니다 |

## 확인 앱

시트를 직접 읽는 macOS 앱입니다. `generate` 를 먼저 돌리지 않아도 됩니다. 모든 언어를 나란히
보고, 변수는 강조되며 값을 넣어 볼 수 있고, 고친 뒤 새로 고칠 수 있습니다. 프로젝트마다 탭이
하나씩 생깁니다.

```bash
ss preview
```

## 설정

```json
{
  "source":  { "path": "strings.csv", "headerRow": 2, "defaultLocale": "ko" },
  "columns": {
    "key": "키", "screen": "화면", "description": "설명",
    "languages": { "ko": "한국어", "en": "영어", "ja": "일본어" }
  },
  "output": { "path": "Sources/Resources", "artifacts": ["xcstrings", "swift"] }
}
```

경로는 설정 파일 기준입니다. 키 전체는 [docs/configuration.ko.md](docs/configuration.ko.md) 에
있습니다.

## 설계상의 선택

- **산출물은 결정적입니다.** 같은 입력이면 같은 바이트가 나오고, 내용이 같으면 다시 쓰지
  않습니다. 생성 파일을 커밋하므로, 실행할 때마다 순서가 흔들리면 매번 충돌이 납니다.
- **빈 번역은 넣지 않습니다.** `translated` 로 넣으면 Xcode 에서 누락이 감춰집니다.
- **파일 안쪽 검증은 다른 도구에 맡깁니다.**
  [LocaleLint](https://forums.swift.org/t/localelint-ci-validation-for-ios-localization-files-string-catalogs-xliff/86939)
  와 [Locheck](https://github.com/irskep/locheck) 이 `.xcstrings` 내부를 봅니다. stringsmith
  는 시트 쪽을 봅니다. 둘 다 쓰세요.

## 예제

[`Examples/DemoApp`](Examples/DemoApp) 은 시트·설정·SwiftUI 앱이 한자리에 있고 실제로 돕니다.
생성된 파일도 읽어 볼 수 있게 커밋해 뒀습니다.

## 개발

```bash
swift build && swift test
python3 Scripts/run-ci.py    # CI 검사 전부를 로컬에서
make release                 # 유니버설 바이너리 + 앱 번들
```

## 라이선스

Apache-2.0 또는 MIT 중 선택.
