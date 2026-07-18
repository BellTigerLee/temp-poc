# scalex-federation 연동용 child 최소 구조

이 저장소는 `scalex-federation`이 원격 Git source로 읽는 단일 Helm chart를 제공한다.
`source.path`는 `chart`로 고정하지만, child promotion용 OCI 채널은 별도로 유지된다.
차트의 기본값은 독립 실행용으로는 유효하지만, 그것만으로 release state를 대표하지는
않는다. Federation은 아직 이 OCI 채널을 consume하지 않는다.

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
- image는 mutable `latest` 대신 commit tag와 registry digest를 사용하며, deployment
  digest는 payload의 `images`에 들어간다.
- child CI는 sole writer이고, immutable run tag
  `sha-<source-sha>-run-<run-id>-attempt-<attempt>`를 initial retention 관점에서
  indefinite하게 남기도록 의도한다.
- `latest-verified`는 discovery channel일 뿐이며, candidate source SHA가 current remote
  `origin/main`과 같을 때만 이동한다. stale completed run은 immutable artifact를 유지하되
  channel을 옮기지 않는다.
- source SHA, image deployment digest, OCI transport digest는 서로 다른 identity다.
  OCI transport digest는 OCI manifest를 식별하며 payload 안에 기록하지 않고
  별도로 emit/verify한다.
- chart는 eecs/smartx/mobilex의 cluster preset이나 infra dependency를 직접 수정하지 않고
  values로 제공되는 endpoint/name을 소비한다.

## 변경 흐름

```text
child push
  → child CI가 chart/image를 검증
  → immutable OCI promotion artifact를 Harbor에 publish
  → current remote `origin/main`이 candidate source SHA와 같으면 `latest-verified` 이동
  → stale run은 artifact만 남기고 channel은 그대로 유지
  → scalex-federation은 아직 이 OCI 채널을 consume하지 않음
```

child CI가 `scalex-federation/main`에 직접 push하거나 자동 merge하지 않는 것을 기본으로
한다. live Harbor retention은 TLS와 policy 검증이 끝나기 전까지 아직 확인되지 않았다.
