#!/bin/bash

POD_PREFIX="todoapp"
NAMESPACE="todoapp"
MAX_AGE_SECONDS=400
YOUNGEST_POD=""
YOUNGEST_TIME=""

echo "Apply StatefulSet and waiting for readiness..."
kubectl apply -f .infrastructure/mysql/statefulSet.yml
echo "Waiting for readiness StatefulSet..."
kubectl rollout status statefulset mysql -n mysql --timeout=300s

echo "Apply Deployment..."
kubectl apply -f .infrastructure/app/deployment.yml
echo "Waiting for readiness deployment..."
kubectl rollout status deployment todoapp -n todoapp --timeout=300s

# Поиск Pod'а с именем, начинающимся на $POD_PREFIX
POD_NAME=$(kubectl get pods -n $NAMESPACE | grep "^$POD_PREFIX" | head -n 1 | awk '{print $1}')

LIST_PODS=$(kubectl get pods -n todoapp | grep "^todoapp" |  awk '{print $1}')

for i in $LIST_PODS; do
  echo "Found Pod: $i"
  CREATION_TIME=$(kubectl get pod $i -n $NAMESPACE -o jsonpath='{.metadata.creationTimestamp}')

  # Если это первый Pod, сохранить его как самый молодой
  if [ -z "$YOUNGEST_TIME" ]; then
    YOUNGEST_POD=$i
    YOUNGEST_TIME=$CREATION_TIME
  else
    # Сравнить время создания текущего Pod'а с самым молодым
    if [[ "$CREATION_TIME" > "$YOUNGEST_TIME" ]]; then
      YOUNGEST_POD=$i
      YOUNGEST_TIME=$CREATION_TIME
    fi
  fi
done

# Проверка, найден ли Pod
if [ -z "$YOUNGEST_POD" ]; then
  echo "Pod's who name begin with '$POD_PREFIX', doesn't found."
  exit 1
fi

# Вывод самого молодого Pod'а
echo "The youngest Pod: $YOUNGEST_POD"
echo "Creation time: $YOUNGEST_TIME"

# Получение времени создания Pod'а
  POD_CREATION_TIME=$(kubectl get pod -n $NAMESPACE $YOUNGEST_POD -o jsonpath="{.metadata.creationTimestamp}")

# Преобразование времени создания в Unix-время
  POD_CREATION_UNIX=$(date -d "$POD_CREATION_TIME" +%s)

# Получение текущего времени в Unix-времени
  CURRENT_UNIX=$(date +%s)

# Вычисление времени жизни Pod'а
  POD_AGE_SECONDS=$((CURRENT_UNIX - POD_CREATION_UNIX))

# Проверка, что время жизни Pod'а не превышает MAX_AGE_SECONDS
if [ "$POD_AGE_SECONDS" -le "$MAX_AGE_SECONDS" ]; then

  # Получение токена (для Kubernetes 1.24+)
  TOKEN=$(kubectl create token todoapp-role -n todoapp)

  kubectl exec $YOUNGEST_POD -n todoapp -- sh -c "curl --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header \
    'Authorization: Bearer $TOKEN' https://kubernetes.default.svc/api/v1/namespaces/todoapp/secrets"

else
  echo "Pod $YOUNGEST_POD lives more than $MAX_AGE_SECONDS sec (TTL: $POD_AGE_SECONDS sec). \
    Perhaps these pods are not from our deployment!"
  exit 1
fi

# Проверка прав ServiceAccount
SERVICE_ACCOUNT="system:serviceaccount:todoapp:todoapp-role"
RESOURCE="secrets"
VERB="list"

if kubectl auth can-i $VERB $RESOURCE --namespace=$NAMESPACE --as=$SERVICE_ACCOUNT >/dev/null 2>&1; then
  echo "ServiceAccount $SERVICE_ACCOUNT has the right to perform the action '$VERB' for '$RESOURCE' in namespace '$NAMESPACE'."
else
  echo "ServiceAccount $SERVICE_ACCOUNT hasn't the right to perform the action '$VERB' for '$RESOURCE' in namespace '$NAMESPACE'."
  exit 0
fi