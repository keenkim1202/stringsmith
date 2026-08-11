# 설정

[English](configuration.md) · 한국어

`.stringsmith.json` 은 현재 디렉터리에서 위로 올라가며 찾습니다. 경로는 전부 설정 파일 자신을
기준으로 하므로 저장소 어디에서 실행해도 동작합니다.

`ss init` 이 하나 만들어 줍니다. 아래 첫 표 밑의 키들은 대부분의 프로젝트가 건드릴 일이
없습니다.

## source

| 키 | |
|---|---|
| `type` | `csv` · `xlsx` · `google-sheets`. 확장자로도 알아봅니다 |
| `path` | 시트 파일. `csv`·`xlsx` 일 때 |
| `url` | Google Sheets 공유 URL |
| `gid` | 그 URL 안의 탭 |
| `tabs` | 이어 붙일 탭. Google Sheets 는 gid, **로그인했다면** 이름도. 엑셀은 시트 이름 |
| `headerRow` | 1부터. 시트 위쪽에 제목 행이 있는 경우가 많습니다 |
| `defaultLocale` | 원문 언어. 카탈로그의 `sourceLanguage` 가 됩니다 |

## columns

시트의 컬럼 이름을 stringsmith 가 아는 이름에 잇습니다. `init` 이 추론합니다.

| 키 | |
|---|---|
| `key` | 문자열 키 |
| `screen` | 선택. 네임스페이스와 주석에 쓰입니다 |
| `description` | 선택. 주석이 됩니다 |
| `languages` | 로케일 코드 → 컬럼 이름 |

매핑하지 않은 컬럼은 무시되고, `init` 이 무엇을 건너뛰었는지 알려 줍니다.

## output

| 키 | |
|---|---|
| `path` | 로컬라이제이션 파일을 둘 곳 |
| `artifacts` | `xcstrings` · `strings` · `stringsdict` · `swift` |
| `tableName` | 기본 `Localizable` |
| `pluralVariable` | 수를 세는 변수. 기본 `count` |
| `swift.enumName` | 기본 `L10n` |
| `swift.namespace` | `keyPrefix` · `screen` · `none` |
| `swift.bundle` | 앱 타깃은 `main`, SwiftPM 리소스는 `module` |
| `swift.path` | 생성 코드를 둘 곳. 없으면 `output.path` |
| `swift.accessLevel` | `public` · `internal` |
| `swift.docComments` | 원문 값을 doc 주석에 넣습니다 |

`swift.path` 는 Swift 패키지에서 중요합니다. SwiftPM 은 `resources:` 디렉터리 아래를 통째로
가져가므로, `.lproj` 옆에 둔 `L10n.swift` 는 컴파일되지 않고 리소스로 복사됩니다.

## placeholders

| 키 | |
|---|---|
| `syntax` | 인식할 표기: `apple`(`%@`) · `brace`(`{name}`) · `xml` |
| `positional` | `auto`(둘 이상일 때 위치 지정자) · `always` · `never` |
| `braceOpen` / `braceClose` / `escape` | 구분자. 기본 `{` `}` `\` |
| `numeric` | `%d` 로 내보낼 변수. 복수형이 알아서 설정합니다 |

`syntax` 가 배열인 건 실제 시트가 표기를 섞어 쓰기 때문입니다 — 예전 파일에서 옮겨온 행은
`%@` 를, 새로 쓴 행은 `{name}` 을 씁니다.

## validation

| 키 | |
|---|---|
| `failOn` | 생성을 막을 경고: `collision` · `missing` · `placeholder` · `key` · `whitespace` · `length` · `plural` · `other` |
| `keyPattern` | 키가 따라야 할 정규식. 없으면 형식만 검사합니다 |
| `lengthFactor` | 중앙값의 몇 배부터 길다고 볼지. 기본 `1.8`, `0` 이면 끕니다 |

`failOn` 의 기본값은 `["collision"]` 입니다. 두 키가 같은 Swift 이름이 되면 나중에는 피해가
보이지 않습니다 — 생성 코드 어디에도 어느 쪽이 어느 키인지 없고, 시트에서 하나를 지우면 남은
키의 이름이 바뀝니다. 번역 누락은 일부러 막지 않습니다. 아직 채우는 중인 시트에는 늘 빈 칸이
있고, iOS 는 번역이 없으면 원문으로 대체합니다.

`failOn` 에 모르는 이름이 있으면 무시합니다. 설정 오타 하나로 빌드를 세우지 않습니다.

## 환경 변수

| 변수 | |
|---|---|
| `STRINGSMITH_LANG` | `en` 또는 `ko`. 없으면 시스템 언어를 따릅니다 |
| `STRINGSMITH_GOOGLE_CLIENT_ID` / `_SECRET` | `~/.config/stringsmith/client.json` 보다 우선 |
| `NO_COLOR` | 색을 끕니다 ([no-color.org](https://no-color.org)) |
| `FORCE_COLOR` · `CLICOLOR_FORCE` | 파이프로 내보낼 때도 색을 켭니다. CI 로그용 |

출력이 터미널이 아니면 색이 꺼집니다. `ss generate > log.txt` 결과가 읽히도록 하기
위해서입니다. `NO_COLOR` 가 `FORCE_COLOR` 를 이깁니다.

## 전체 예시

로그인한 상태를 전제로 탭을 gid 가 아니라 이름으로 적었습니다.

```json
{
  "source": {
    "type": "google-sheets",
    "url": "https://docs.google.com/spreadsheets/d/{ID}/edit",
    "tabs": ["common", "checkout"],
    "headerRow": 2,
    "defaultLocale": "ko"
  },
  "columns": {
    "key": "키",
    "screen": "화면",
    "description": "설명",
    "languages": { "ko": "한국어", "en": "영어", "ja": "일본어" }
  },
  "output": {
    "path": "Sources/App/Resources",
    "artifacts": ["strings", "stringsdict", "swift"],
    "swift": { "path": "Sources/App/Generated", "bundle": "module" }
  },
  "validation": { "failOn": ["collision", "missing"] }
}
```
