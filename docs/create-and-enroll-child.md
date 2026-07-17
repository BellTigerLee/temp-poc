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
- 이미지는 `latest`가 아니라 commit tag와 registry digest를 사용한다.

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

각 image는 registry에 immutable tag로 push한다.

```text
<registry>/<child>-<component>:sha-<40-character-commit-sha>
```

registry가 반환한 digest와 child commit SHA를 기록한다. Federation release의 `revision`과
image `sourceRevision`은 동일한 child commit을 가리켜야 한다.

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
`values.yaml`에는 image repository/tag/digest, workload 설정, Karmada placement와 같은
배포 override만 넣는다.

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

child CI가 promotion PR을 자동 생성하는 경우에도 Federation `main`에 직접 push하거나
자동 merge하지 않는다. 현재 `temp-poc` workflow의 GitHub App 연동을 재사용하려면 다음을
child repository의 Actions 설정에 등록한다.

```text
Repository variable:
  SCALEX_PROMOTION_APP_ID=<numeric GitHub App ID>

Repository secrets:
  SCALEX_PROMOTION_APP_PRIVATE_KEY=<full PEM, including BEGIN/END lines>
  DOCKERHUB_USERNAME=<registry account>
  DOCKERHUB_TOKEN=<registry token>
```

GitHub App은 `scalex-federation`에 설치되어 있어야 하며 `Contents: read/write`와
`Pull requests: read/write` 권한이 필요하다. workflow의 push 대상 branch와 job `if` 조건도
실제 운영 branch(`main` 또는 feature branch)에 맞춰 동일하게 설정한다.

## 7. 활성화 전 확인 목록

- [ ] child repository의 `chart/`가 Helm lint/render를 통과한다.
- [ ] `contracts/children.yaml`의 repo URL과 `chart` path가 실제와 일치한다.
- [ ] release `revision`이 40자리 commit SHA다.
- [ ] image tag, digest, `sourceRevision`이 같은 commit을 가리킨다.
- [ ] 대상 member cluster에 namespace와 infra dependency가 존재한다.
- [ ] `state: active` 전환 후 Federation validation이 통과한다.
- [ ] ArgoCD sync 후 Karmada ResourceBinding과 member workload를 확인한다.
