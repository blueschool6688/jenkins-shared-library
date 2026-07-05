IMAGE_NAME=$1
IMAGE_TAG=$2

FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

export APP_NAME="${APP_NAME:-}"
export DOMAIN="${DOMAIN:-$APP_NAME}"
export BAO_SECRET_PATH="${BAO_SECRET_PATH:-}"
export BAO_SECRET_VERSION="${BAO_SECRET_VERSION:-3}" 
if [ -z "$APP_NAME" ]; then
    echo "❌ LỖI: Biến APP_NAME chưa được set từ môi trường!"
    exit 1
fi

if [ -z "$BAO_SECRET_PATH" ]; then
    echo "❌ LỖI: Biến BAO_SECRET_PATH chưa được set từ môi trường!"
    exit 1
fi

export BAO_ADDR="${BAO_ADDR:-}"
export BAO_TOKEN="${BAO_TOKEN:-}"
TEMP_ENV_FILE="/tmp/.deploy-${APP_NAME}-$(date +%s%N).env"

fetch_secrets_from_openbao() {
    echo "[PRE] 🔍 Kiểm tra kết nối OpenBao tại ${BAO_ADDR}..."
    if ! curl -sk --max-time 5 "${BAO_ADDR}/v1/sys/health" > /dev/null 2>&1; then
        echo "❌ LỖI: Không thể kết nối OpenBao!"
        exit 1
    fi

    if [ -z "${BAO_TOKEN}" ]; then
        echo "❌ LỖI: Biến BAO_TOKEN chưa được set!"
        echo "   Truyền token khi chạy: BAO_TOKEN=<your-token> bash deploy.sh ..."
        exit 1
    fi

    BAO_ADDR="${BAO_ADDR%/}"
    PATHS_TO_TRY=(
        "secret/data/${BAO_SECRET_PATH}"
        "$(echo "${BAO_SECRET_PATH}" | sed 's|/|/data/|')"
        "kv/data/${BAO_SECRET_PATH}"
        "${BAO_SECRET_PATH}"
    )

    SUCCESS=0
    for API_PATH in "${PATHS_TO_TRY[@]}"; do
        API_PATH=$(echo "$API_PATH" | sed 's|//|/|g')
        RESPONSE=$(curl -s -H "X-Vault-Token: ${BAO_TOKEN}" "${BAO_ADDR}/v1/${API_PATH}?version=${BAO_SECRET_VERSION}")
        
        if echo "${RESPONSE}" | jq -e '.data.data' > /dev/null 2>&1; then
            SECRET_JSON="${RESPONSE}"
            SUCCESS=1
            break
        fi
        SECRET_JSON="${RESPONSE}"
    done

    if [ "$SUCCESS" -eq 0 ]; then
        echo "❌ LỖI: Không thể lấy secrets từ OpenBao! Path: ${BAO_SECRET_PATH}"
        echo "   Chi tiết: ${SECRET_JSON}"
        exit 1
    fi

    echo "${SECRET_JSON}" \
        | jq -r '.data.data | to_entries[] | "\(.key)=\(.value | @json)"' \
        > "${TEMP_ENV_FILE}"

    if [ ! -s "${TEMP_ENV_FILE}" ]; then
        echo "❌ LỖI: File .env tạm rỗng — kiểm tra lại secret path hoặc quyền truy cập!"
        exit 1
    fi

    local KEY_COUNT
    KEY_COUNT=$(wc -l < "${TEMP_ENV_FILE}")
    echo "[PRE] ✅ Lấy thành công ${KEY_COUNT} keys từ OpenBao."
}

# cleanup_temp_env() {
#     if [ -f "${TEMP_ENV_FILE}" ]; then
#         rm -f "${TEMP_ENV_FILE}"
#         echo "[CLEANUP] 🗑️  File .env tạm đã được xóa."
#     fi
# }

# trap cleanup_temp_env EXIT

echo "================================================="
echo "🚀 Bắt đầu Deploy ZERO-DOWNTIME (Blue-Green) Image: ${FULL_IMAGE}"
echo "================================================="

fetch_secrets_from_openbao

echo "[1/6] Pulling new image on server..."

if [ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKER_PASSWORD:-}" ]; then
    echo "Logging into Docker Hub on server..."
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
fi

docker pull ${FULL_IMAGE}

if docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}-blue$"; then
    CURRENT_ENV="blue"
    NEW_ENV="green"
elif docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}-green$"; then
    CURRENT_ENV="green"
    NEW_ENV="blue"
else
    CURRENT_ENV="legacy"
    NEW_ENV="green"
fi


docker rm -f ${APP_NAME}-${NEW_ENV} 2>/dev/null || true

docker run -d \
    --name ${APP_NAME}-${NEW_ENV} \
    --env-file "${TEMP_ENV_FILE}" \
    --restart unless-stopped \
    -p 127.0.0.1::80 \
    ${FULL_IMAGE}

if [ $? -ne 0 ]; then
    echo "❌ LỖI: Không thể khởi chạy container mới ${APP_NAME}-${NEW_ENV}!"
    exit 1
fi

NEW_PORT=$(docker port ${APP_NAME}-${NEW_ENV} 80 | awk -F ':' '{print $2}')
if [ -z "$NEW_PORT" ]; then
    echo "❌ LỖI: Không thể lấy dynamic port từ container!"
    exit 1
fi
echo "=> Container mới đã bind vào port động trên máy chủ: ${NEW_PORT}"

echo "[4/6] Đợi 5 giây cho ứng dụng trong container khởi động hoàn toàn..."
sleep 5

if ! docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}-${NEW_ENV}$"; then
    echo "❌ LỖI: Container mới ${APP_NAME}-${NEW_ENV} không hoạt động hoặc đã bị crash!"
    exit 1
fi

echo "[5/6] Cập nhật Nginx trỏ vào port ${NEW_PORT}..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

if [ -f "$NGINX_CONF" ]; then
    sed -i -E "s/proxy_pass http:\/\/(127\.0\.0\.1|localhost):[0-9]+/proxy_pass http:\/\/127.0.0.1:${NEW_PORT}/g" $NGINX_CONF

    systemctl reload nginx
    echo "Nginx đã được reload!"
else
    echo "⚠️ CẢNH BÁO: Không tìm thấy file $NGINX_CONF"
    echo "Bạn phải cấu hình lại đường dẫn file NGINX cho đúng hoặc tạo file cấu hình cho ${DOMAIN}."
fi

if [ "$CURRENT_ENV" = "legacy" ]; then
    echo "[6/6] Xóa container cũ (${APP_NAME})..."
    docker stop ${APP_NAME} || true
    docker rm ${APP_NAME} || true
else
    echo "[6/6] Xóa container cũ (${APP_NAME}-${CURRENT_ENV})..."
    docker stop ${APP_NAME}-${CURRENT_ENV} || true
    docker rm ${APP_NAME}-${CURRENT_ENV} || true
fi

docker image prune -f

echo "================================================="
echo "🎉 Deploy Zero-Downtime thành công cho ${APP_NAME}!"
echo "================================================="
