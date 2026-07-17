# scalex-federation 연동용 child 최소 구조

이 저장소는 `scalex-federation`이 원격 Git source로 읽는 단일 Helm chart를 제공한다.
Federation release의 `source.path`는 `chart`로 고정하고, 배포용 image 값은 Federation이
관리하는 release values에서 주입한다.

## 최소 디렉터리

```text
temp-poc/
├── chart/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json       # 선택: values 검증
│   └── templates/               # 렌더링 가능한 Kubernetes 리소스
├── src/                         # 애플리케이션 소스(선택)
├── images/                      # Dockerfile(이미지 사용 시)
└── docs/
```

필수 항목은 `chart/Chart.yaml`, `chart/values.yaml`, `chart/templates/`이다. chart는
`helm lint chart`와 `helm template`으로 독립 렌더링되어야 하며, template이 참조하는
모든 값은 `values.yaml` 또는 schema에 선언한다.

## Federation이 요구하는 child 계약

```yaml
source:
  repoURL: https://github.com/<owner>/<repo>.git
  path: chart
  revision: <40-character commit SHA>
values:
  path: releases/<release-name>/values.yaml
```

- `revision`은 mutable branch가 아닌 exact commit SHA를 사용한다.
- release 이름과 chart의 `fullnameOverride`/name label은 충돌하지 않아야 한다.
- Namespace, PropagationPolicy, OverridePolicy 등 chart가 소유하는 namespaced 리소스는
  chart 안에서 함께 렌더링한다. member namespace 자체는 child가 직접 만들지 않는다.
- Secret 값과 장기 credential은 Git에 저장하지 않는다.
- image는 mutable `latest` 대신 commit tag와 registry digest를 사용한다.
- chart는 eecs/smartx/mobilex의 cluster preset이나 infra dependency를 직접 수정하지 않고
  values로 제공되는 endpoint/name을 소비한다.

## 변경 흐름

```text
child push
  → child CI가 chart/image를 검증
  → promotion 값에 source SHA와 image digest 기록
  → scalex-federation release PR
  → ArgoCD가 federation main을 동기화
```

child CI가 `scalex-federation/main`에 직접 push하거나 자동 merge하지 않는 것을 기본으로
한다.
