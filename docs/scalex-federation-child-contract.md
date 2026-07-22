# scalex-federation child 최소 계약

이 문서는 특정 기능을 복제하는 방법이 아니라, 독립된 팀이 소유한 repository를
`scalex-federation`에 연결하기 위해 지켜야 할 최소 구조와 소유권을 정의한다.
`temp-poc`의 Python 서비스, 다중 이미지 build, promotion script는 참고 구현이며 필수
계약이 아니다. 최소 구현 예시는 workspace의 `sample-poc/`에 있다.

## 1. 세 저장소 경계

| 저장소 | 소유하는 것 | 소유하지 않는 것 |
|---|---|---|
| child repository | 애플리케이션 source, image, 하나의 Helm chart, workload, namespaced Karmada policy | Federation catalog, member cluster infra, Secret 원문 |
| `scalex-federation` | 허용 source URL, exact child commit, release 상태, 배포별 values | child template, image build, member cluster 직접 변경 |
| `eecs-k8s`와 각 `*-k8s` | namespace, CNI/CSI, storage, Secret/ConfigMap 등 infra dependency | child workload와 그 placement policy |

동일한 `cluster + namespace + apiVersion/kind + name`은 두 GitOps 경로가 동시에
관리하지 않는다. child는 infra를 생성하지 않고 values로 이름만 받는다.

## 2. 최소 repository 구조

```text
my-child/
├── .github/workflows/validate.yaml  # 권장: 로컬 검증을 CI에서도 실행
├── chart/
│   ├── Chart.yaml                   # Helm v3 application chart
│   ├── values.yaml                  # 독립 렌더 가능한 기본값
│   ├── values.schema.json           # 권장: values 입력 경계
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml          # 실제 child workload
│       └── propagation-policy.yaml  # workload와 같은 chart가 소유
├── scripts/validate.sh
└── README.md
```

필수 배포 단위는 `chart/` 하나다. `src/`, `images/`, Service, RBAC,
`OverridePolicy`는 실제 기능에 필요할 때만 추가한다. Federation이 읽는 기본 경로는
`chart`이며, child 안에 `releases/`나 Federation용 `Application`을 만들지 않는다.

## 3. Helm 계약

- `Chart.yaml`은 `apiVersion: v2`, `type: application`을 사용한다.
- 모든 namespaced resource는 `metadata.namespace: {{ .Release.Namespace }}`를 사용한다.
  고정 namespace를 template에 넣지 않는다.
- label과 policy `resourceSelectors`는 같은 helper에서 이름을 만들고 정확히 일치시킨다.
- 기본 values만으로 `helm lint --strict chart`와 `helm template`이 성공해야 한다.
- `fullnameOverride`는 선택 사항이다. 기본적으로 Argo가 전달하는 Helm release name이
  resource 이름의 기준이 되게 한다.
- Namespace, Secret, OBC/PVC, ingress controller 같은 infra resource는 chart에 넣지 않는다.
- cluster-scoped `ClusterRole`, `ClusterRoleBinding`, `ClusterPropagationPolicy`,
  `ClusterOverridePolicy`는 현재 Federation AppProject 범위 밖이다.

## 4. Karmada 계약

Federation 경로에서 chart는 최소 하나의 namespaced
`policy.karmada.io/v1alpha1/PropagationPolicy`를 렌더링해야 한다.

```yaml
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  namespace: {{ .Release.Namespace }}
spec:
  resourceSelectors:
    - apiVersion: apps/v1
      kind: Deployment
      name: <같은 chart가 렌더링한 이름>
      namespace: {{ .Release.Namespace }}
  placement:
    clusterAffinity:
      clusterNames:
        - <values로 받은 member 이름>
```

한 workload resource는 정확히 하나의 `PropagationPolicy`가 선택하게 한다. Service 등
같이 이동해야 하는 resource는 같은 policy selector에 추가할 수 있다. member별 필드
변경이 실제로 필요할 때만 namespaced `OverridePolicy`를 추가한다. local Helm 사용을
지원한다면 `karmada.enabled=false`로 policy를 끌 수 있지만 Federation values에서는
반드시 `true`여야 한다.

## 5. release와 image 불변성

- Federation `source.revision`은 branch/tag가 아니라 40자리 child commit SHA다.
- 최종 Deployment image는 `repository:tag@sha256:<64 hex>`로 렌더링한다.
- tag는 사람이 읽는 version이고 digest가 실제 배포 identity다. `latest`를 최고 version으로
  해석하지 않는다.
- image build/push, scan, promotion 자동화는 child별 선택 구현이다. 최소 계약은 검증된
  digest를 Federation values에 제공하는 것뿐이다.
- credential과 Secret 원문은 child/Federation Git에 저장하지 않는다.

## 6. 현재 Federation 이름 규칙

외부 repository 이름은 자유롭지만 현재 AppProject destination은 `scalex-*` namespace만
허용한다. 따라서 repository가 `sample-poc`이라도 release ID와 namespace는
`scalex-sample-poc`처럼 정한다. release 디렉터리명, `release.yaml`의 `name`, namespace는
동일하게 유지하고 `source.repoURL`만 실제 외부 repository URL을 사용한다.

## 7. 최소 검증 기준

```bash
./scripts/validate.sh
helm template scalex-my-child chart \
  --namespace scalex-my-child \
  --set karmada.enabled=true \
  --set karmada.placement.cluster=<member-name>
```

렌더 결과에서 다음을 확인한다.

- 모든 namespaced resource가 release namespace를 사용한다.
- workload와 policy selector의 apiVersion/kind/name/namespace가 일치한다.
- Federation render에서 policy가 빠지지 않는다.
- 모든 workload image에 digest가 있다.
- Secret/OBC와 cluster-scoped resource가 없다.

## 8. 기준 구현 비교

세 운영 repository는 child scaffold가 아니므로 파일 구조를 복사하지 않고 다음 관례만
채택했다.

- `eecs-k8s/apps/openark-gitops/manifest.yaml`과
  `eecs-k8s/apps/openark-gitops/templates/workload-template-ci.yaml`은 chart resource가
  `.Release.Namespace`를 따르는 관례를 보여 준다.
  `eecs-k8s/apps/karmada-members/templates/join.yaml`은 Tower가 Karmada destination과
  member를 준비하는 infra 경로다. child가 이 로직을 포함하면 안 된다.
- `smartx-k8s/apps/openark-gitops/manifest.yaml`과
  `smartx-k8s/apps/openark-gitops/templates/workload-template-ci.yaml`은 EECS와 같은 chart
  관례를 사용하지만 이 repository에는 EECS의 `apps/karmada-members/` 구현이 없다.
  따라서 두 repository의 cluster 준비 상태를 동일하다고 가정하지 않는다.
- `mobilex-k8s/charts/ssh/kangryeol/application.yaml`은 외부 chart와 cluster-owned values를
  분리하고 `CreateNamespace=false`를 사용한다. 이는 소유권 분리의 참고이지만 Argo가
  MobileX cluster에 직접 배포하는 구조이며, Tower Argo → Karmada 경로인 Federation
  child와는 다르다.

실제 Federation 계약의 기준은 `scalex-federation/bootstrap/applicationset.yaml`,
`scalex-federation/bootstrap/appproject.yaml`, `scalex-federation/docs/common-contract.md`,
`scalex-federation/releases/README.md`다.
