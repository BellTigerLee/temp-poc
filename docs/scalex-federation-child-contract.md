# scalex-federation 연동용 child 최소 구조

이 저장소는 `scalex-federation`이 원격 Git source로 읽는 단일 Helm chart를 제공한다.
`source.path`는 `chart`로 고정한다. 차트의 기본값은 독립 실행용으로는 유효하지만,
그것만으로 immutable release state를 대표하지는 않는다.

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
모든 값은 `values.yaml` 또는 schema에 선언한다. child CI가 chart 값을 커밋해서 release
state를 대신하는 방식은 사용하지 않는다.

## Federation이 요구하는 child 계약

```yaml
source:
  repoURL: https://github.com/<owner>/<repo>.git
  path: chart
  revision: <40-character commit SHA>
values:
  path: releases/<release-name>/values.yaml
```

- `revision`은 mutable branch가 아닌 exact commit SHA를 사용하며, payload에서는
  `source.revision`에 들어간다.
- release 이름과 chart의 `fullnameOverride`/name label은 충돌하지 않아야 한다.
- Namespace, PropagationPolicy, OverridePolicy 등 chart가 소유하는 namespaced 리소스는
  chart 안에서 함께 렌더링한다. member namespace 자체는 child가 직접 만들지 않는다.
- Secret 값과 장기 credential은 Git에 저장하지 않는다.
- image는 mutable `latest` 대신 명시된 stable `vX.Y.Z` tag와 registry digest를
  사용하며, deployment digest는 payload의 `images`에 들어간다.
- ORAS publication을 활성화하면 child CI는 promotion artifact의 sole writer이고,
  immutable run tag
  `sha-<source-sha>-run-<run-id>-attempt-<attempt>`를 initial retention 관점에서
  indefinite하게 남기도록 의도한다.
- child는 명시된 `tag: latest`를 일반 tag 그대로 처리할 수 있지만, 이를 최고 SemVer로
  해석하거나 `latest-verified` selection channel을 생성·이동하지 않는다. 검증된
  SemVer의 선택과 digest pinning은 Federation의 책임이다.
- source SHA, image deployment digest, OCI transport digest는 서로 다른 identity다.
  OCI transport digest는 OCI manifest를 식별하며 payload 안에 기록하지 않고
  별도로 emit/verify한다.
- chart는 eecs/smartx/mobilex의 cluster preset이나 infra dependency를 직접 수정하지 않고
  values로 제공되는 endpoint/name을 소비한다.

## 변경 흐름

```text
child push
  → child CI가 chart와 임의 image map을 검증
  → Dockerfile이 있는 image는 명시 repository:tag로 build/push
  → Dockerfile이 없는 image는 기존 repository:tag digest 조회
  → generated values와 promotion payload 생성
  → Federation이 검증된 promotion 중 배포 version을 선택하고 exact digest를 pin
  → Helm이 최종 값을 Kubernetes manifest로 render
```

child CI가 `scalex-federation/main`에 직접 push하거나 자동 merge하지 않는 것을 기본으로
한다. live Harbor retention은 TLS와 policy 검증이 끝나기 전까지 아직 확인되지 않았다.
