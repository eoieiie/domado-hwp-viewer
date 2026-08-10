# 도마도 HWP 뷰어

한컴오피스 없이 `.hwp` / `.hwpx` 문서를 읽는 macOS 앱.

맥에는 한글 문서를 볼 무료 수단이 사실상 없다. 한컴오피스는 유료 구독이고,
온라인 변환 사이트는 학교 서류를 남의 서버에 올려야 한다.

- **의존성 0** — 표준 라이브러리와 시스템 프레임워크만 사용
- **784KB** — Electron 계열이면 수십 MB
- 파일이 밖으로 나가지 않음 (네트워크 통신 없음)

## 기능

- 드래그 앤 드롭 / `⌘O` / Finder "다음으로 열기"
- 문서 내 검색 (일치 항목 하이라이트)
- 표 구조 들여쓰기
- `.txt` 저장 (`⌘S`), 전체 복사 (`⌘⇧C`)
- 확장자가 틀려도 컨테이너 시그니처로 판별

## 빌드

```bash
swift build -c release --product HwpViewer
```

CLI만 필요하면:

```bash
swift run hwpcli 문서.hwp        # 본문 출력
swift run hwpcli 문서.hwp -i     # 표 들여쓰기 포함
```

## 구조

```
Sources/
├── HwpKit/                 파서 (UI 비의존)
│   ├── CompoundFile.swift  OLE 컨테이너 (CFBF)
│   ├── ZipArchive.swift    최소 ZIP 리더 (.hwpx용)
│   ├── HwpDocument.swift   포맷 판별 + 바이너리 레코드 파싱
│   └── HwpxParser.swift    OWPML XML 파싱
├── hwpcli/                 터미널 도구
└── HwpViewer/              SwiftUI 앱
```

## 포맷 메모

### .hwp — 3겹 구조

```
OLE Compound File (CFBF)
└─ BodyText/Section0
   └─ raw DEFLATE
      └─ 레코드 스트림: [32비트 헤더][페이로드]
         헤더 = tag(10) | level(10) | size(12)
         size == 0xFFF 이면 다음 4바이트가 실제 크기
```

본문은 `tag == 67`(PARA_TEXT), UTF-16LE.
제어문자 중 `1~8, 11~23`은 **16바이트(8 units)** 를 차지한다. 2바이트로 세면
이후 모든 글자가 밀린다.

레벨은 컨테이너마다 2씩 증가한다 — 본문 문단 1, 표 셀 3, 중첩 표 5.

### .hwpx — zip + XML

`Contents/section0.xml` 안에서 `<hp:p>`가 문단, `<hp:t>`가 텍스트 런,
`<hp:tbl>`이 표. 훨씬 단순하다.

## 검증

스펙 문서 없이 만든 파서라 **독립 구현 2개를 교차 검증**했다.
Python 참조 구현과 Swift 구현의 출력을 diff로 비교 — 120문단 완전 일치.

## 남은 것

- 표 셀 병합 정보 (현재는 셀을 순서대로 나열)
- Quick Look 확장 (스페이스바 미리보기)
- 이미지 추출
- 코드 서명 · 공증
