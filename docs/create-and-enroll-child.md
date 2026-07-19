# 새로운 child 만들기와 scalex-federation 연결하기

이 문서는 다른 개발자가 자신의 feature repository를 만들고,
`scalex-federation`을 통해 Tower Karmada에 배포하기 위한 최소 절차를 설명한다.

## 1. child repository 생성

처음부터 다음 구조를 만든다.

```text
my-child/
├── chart/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json       # 선택
│   └── templates/
│       ├── deployment.yaml      # 필요한 workload
│       ├── service.yaml         # 필요한 경우
│       └── policy/              # Karmada policy가 필요하면 chart가 소유
├── images/                      # 이미지를 직접 빌드할 때만
├── src/                         # 애플리케이션 소스
└── docs/
```

필수 조건은 다음과 같다.

- `chart/Chart.yaml`은 Helm v3 application chart여야 한다.
- `chart/values.yaml`에 모든 기본값을 선언한다.
- `chart/templates/`는 `helm lint chart`와 `helm template`으로 렌더링되어야 한다.
- chart는 배포 대상 namespace를 사용하지만 member namespace 자체를 직접 생성하지 않는다.
  namespace는 각 `*-k8s` 운영 repository에서 먼저 준비한다.
- Secret 원문과 장기 credential을 Git에 저장하지 않는다.
- 사용자용 base values에는 명시된 stable `vX.Y.Z` tag를 사용한다. `latest`는 가장
  높은 version이 아니므로 Child의 version 선택 값으로 사용하지 않는다.

## 2. child를 로컬에서 검증

최소 검증은 다음과 같다.

```bash
helm lint --strict chart
helm template my-child chart --namespace <workload-namespace> >/tmp/my-child.yaml
```

workload, Service, `PropagationPolicy`, `OverridePolicy`가 모두 기대한 namespace와
cluster selector를 사용하는지 확인한다. child가 Python/Go 등 애플리케이션을 포함하면
언어별 테스트와 image build도 함께 통과시킨다.

## 3. image 준비

각 image는 `chart/values.yaml`에 명시한 stable version tag로 push한다.

```text
<registry>/<child>-<component>:v0.1.0
```

같은 tag가 이미 있어도 build/push를 시도하며, Harbor immutable-tag policy가 설정된
경우 registry가 덮어쓰기를 거부할 수 있다. registry가 반환한 digest와 child commit
SHA는 generated values에 기록한다. Federation release의 `revision`과 image
`sourceRevision`은 동일한 child commit을 가리켜야 한다.

## 4. Federation에 child 등록

`scalex-federation`의 `contracts/children.yaml`에 repository와 chart path를 추가한다.

```yaml
- name: my-child
  repoURL: https://github.com/<owner>/my-child.git
  paths:
    - chart
```

그 다음 `releases/my-child/`를 만들고 두 파일을 추가한다.

```text
releases/my-child/
├── release.yaml
└── values.yaml
```

`release.yaml` 예시:

```yaml
name: my-child
namespace: scalex-my-child
state: disabled
renderer: helm/v1
source:
  repoURL: https://github.com/<owner>/my-child.git
  path: chart
  revision: <40-character-child-commit-sha>
values:
  path: releases/my-child/values.yaml
promotion:
  mode: tracked
```

처음에는 `state: disabled`로 검증하고, chart와 values가 준비되면 `active`로 바꾼다.
`values.yaml`에는 사용자 소유 image repository/tag/pullPolicy, workload 설정, Karmada
placement 같은 배포 override만 넣는다. digest와 source revision은 CI promotion
payload가 관리한다.

## 5. namespace와 infra dependency 준비

`scalex-my-child` namespace와 OBC/PVC, 외부 endpoint 같은 infra dependency는 child chart나
Federation release에 넣지 않는다. 대상 클러스터의 `b-k8s`, `c-k8s` 등 운영 repository에서
먼저 준비하고, child는 values로 이름과 endpoint만 참조한다.

## 6. Pull Request와 배포

두 저장소의 변경을 각각 Pull Request로 검토한다.

1. child repository: chart, source, image build와 local validation
2. `scalex-federation`: enrollment, `releases/<name>/release.yaml`, `values.yaml`
3. federation PR merge 후 Tower ArgoCD가 Karmada destination에 동기화
4. Karmada가 placement에 따라 member cluster에 workload를 전파

child CI는 promotion PR을 자동 생성하거나 Federation `main`에 직접 push하지 않는다.
`temp-poc`의 image flow에서는 `chart/values.yaml`의 임의 image map을 읽는다.
`images/<key>/Dockerfile`이 있으면 명시된 `repository:tag`를 항상 build/push하고,
없으면 기존 image의 digest만 조회한다. digest와 source revision은 별도의 generated
values와 promotion payload로 생성하며 base values에 commit하지 않는다. 현재 ORAS
publication은 비활성화되어 있다. 명시적으로 `tag: latest`를 지정하면 일반 tag 그대로
처리할 뿐 최고 version을 조회하거나 별도 tag를 자동 생성하지 않는다. ORAS를 다시
활성화하더라도 child는 immutable OCI artifact만 publish하고 `latest-verified` 같은
selection channel을 이동하지 않는다.

검증된 promotion 중 가장 높은 SemVer를 선택하고 repository, tag, digest를 고정하는
정책은 Federation의 책임이다. Helm은 그 최종 선택을 manifest로 렌더링할 뿐 Harbor를
조회하거나 image version을 선택하지 않는다.

CI가 `chart/values.yaml` 또는 generated values를 commit하는 경로는 사용하지 않는다.

현재 simplified flow에서는 GitHub App 기반 cross-repository promotion 설정을 사용하지
않는다. child CI는 `HARBOR_USERNAME`과 `HARBOR_PASSWORD`로 기존 Harbor
repository에 publish/pull만 수행하고, workflow는 GitHub `contents: read` 및 no Git
write permission을 유지한다. immutable run tag는 초기에는 무기한 보관을 의도하지만,
실제 Harbor retention은 TLS와 policy 검증이 끝나기 전까지 아직 확인되지 않았다.

## 7. 활성화 전 확인 목록

- [ ] child repository의 `chart/`가 Helm lint/render를 통과한다.
- [ ] `contracts/children.yaml`의 repo URL과 `chart` path가 실제와 일치한다.
- [ ] release `revision`이 40자리 commit SHA다.
- [ ] promotion payload의 image tag, digest, `sourceRevision`이 같은 commit을 가리킨다.
- [ ] 대상 member cluster에 namespace와 infra dependency가 존재한다.
- [ ] `state: active` 전환 후 Federation validation이 통과한다.
- [ ] ArgoCD sync 후 Karmada ResourceBinding과 member workload를 확인한다.
