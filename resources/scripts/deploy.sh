#!/bin/bash

# Script này nhận 2 tham số truyền vào từ Jenkins
IMAGE_NAME=$1
IMAGE_TAG=$2

FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

# Các biến này được set env từ bên ngoài (Jenkinsfile / Pipeline)
export APP_NAME="${APP_NAME:-}"
export DOMAIN="${DOMAIN:-$APP_NAME}"
export BAO_SECRET_PATH="${BAO_SECRET_PATH:-}"
export BAO_SECRET_VERSION="${BAO_SECRET_VERSION:-3}" # Thêm version cho bao
if [ -z "$APP_NAME" ]; then
    echo "❌ LỖI: Biến APP_NAME chưa được set từ môi trường!"
    exit 1
fi

if [ -z "$BAO_SECRET_PATH" ]; then
    echo "❌ LỖI: Biến BAO_SECRET_PATH chưa được set từ môi trường!"
    exit 1
fi

# Địa chỉ OpenBao server (có thể override bằng biến môi trường BAO_ADDR)
export BAO_ADDR="${BAO_ADDR:-}"
# Token xác thực (có thể override bằng biến môi trường BAO_TOKEN)
export BAO_TOKEN="${BAO_TOKEN:-}"
TEMP_ENV_FILE="/tmp/.deploy-$(date +%s%N).env"

fetch_secrets_from_openbao() {
    # Kiểm tra kết nối OpenBao trước khi lấy secrets
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

    # Kiểm tra file được tạo và có nội dung
    if [ ! -s "${TEMP_ENV_FILE}" ]; then
        echo "❌ LỖI: File .env tạm rỗng — kiểm tra lại secret path hoặc quyền truy cập!"
        exit 1
    fi

    local KEY_COUNT
    KEY_COUNT=$(wc -l < "${TEMP_ENV_FILE}")
    echo "[PRE] ✅ Lấy thành công ${KEY_COUNT} keys từ OpenBao."
}

cleanup_temp_env() {
    if [ -f "${TEMP_ENV_FILE}" ]; then
        rm -f "${TEMP_ENV_FILE}"
        echo "[CLEANUP] 🗑️  File .env tạm đã được xóa."
    fi
}

# Đảm bảo file tạm luôn bị xóa dù script exit thành công hay lỗi
trap cleanup_temp_env EXIT

echo "================================================="
echo "🚀 Bắt đầu Deploy ZERO-DOWNTIME (Blue-Green) Image: ${FULL_IMAGE}"
echo "================================================="

# PRE. Lấy secrets từ OpenBao
fetch_secrets_from_openbao

# 1. Kéo image mới
echo "[1/6] Pulling new image on server..."

# Đăng nhập Docker Hub nếu có credentials (để pull private image)
if [ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKER_PASSWORD:-}" ]; then
    echo "Logging into Docker Hub on server..."
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
fi

docker pull ${FULL_IMAGE}

# 2. Xác định môi trường đang chạy (Blue hay Green)
if docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}-blue$"; then
    CURRENT_ENV="blue"
    NEW_ENV="green"
elif docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}-green$"; then
    CURRENT_ENV="green"
    NEW_ENV="blue"
else
    # Nếu chạy lần đầu hoặc từ container tên cũ
    CURRENT_ENV="legacy"
    NEW_ENV="green"
fi

echo "[2/6] Môi trường hiện tại là ${CURRENT_ENV}. Đang chuẩn bị bật môi trường mới ${NEW_ENV} (với port tự động)..."

# 3. Khởi động container MỚI
echo "[3/6] Chạy container mới..."
# Xóa container cũ trùng tên (nếu có, kể cả đang chạy hoặc đã dừng) để tránh lỗi xung đột tên
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

# Lấy port host ngẫu nhiên đã được Docker cấp phát
NEW_PORT=$(docker port ${APP_NAME}-${NEW_ENV} 80 | awk -F ':' '{print $2}')
if [ -z "$NEW_PORT" ]; then
    echo "❌ LỖI: Không thể lấy dynamic port từ container!"
    exit 1
fi
echo "=> Container mới đã bind vào port động trên máy chủ: ${NEW_PORT}"

# 4. Đợi container mới sẵn sàng
echo "[4/6] Đợi 5 giây cho ứng dụng trong container khởi động hoàn toàn..."
sleep 5

# Kiểm tra xem container mới có đang hoạt động tốt không
if ! docker ps --format '{{.Names}}' | grep -Eq "^${APP_NAME}-${NEW_ENV}$"; then
    echo "❌ LỖI: Container mới ${APP_NAME}-${NEW_ENV} không hoạt động hoặc đã bị crash!"
    exit 1
fi

# 5. Đổi hướng Nginx sang container mới và Reload (KHÔNG DOWNTIME)
echo "[5/6] Cập nhật Nginx trỏ vào port ${NEW_PORT}..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

if [ -f "$NGINX_CONF" ]; then
    # Thay thế port cũ thành port mới trong cấu hình proxy_pass (hỗ trợ cả localhost và 127.0.0.1)
    sed -i -E "s/proxy_pass http:\/\/(127\.0\.0\.1|localhost):[0-9]+/proxy_pass http:\/\/127.0.0.1:${NEW_PORT}/g" $NGINX_CONF

    # Reload Nginx (Thao tác này kết nối cũ vẫn giữ, kết nối mới vào port mới -> Zero Downtime)
    systemctl reload nginx
    echo "Nginx đã được reload!"
else
    echo "⚠️ CẢNH BÁO: Không tìm thấy file $NGINX_CONF"
    echo "Bạn phải cấu hình lại đường dẫn file NGINX cho đúng hoặc tạo file cấu hình cho ${DOMAIN}."
fi

# 6. Tắt và xóa container CŨ
if [ "$CURRENT_ENV" = "legacy" ]; then
    echo "[6/6] Xóa container cũ (${APP_NAME})..."
    docker stop ${APP_NAME} || true
    docker rm ${APP_NAME} || true
else
    echo "[6/6] Xóa container cũ (${APP_NAME}-${CURRENT_ENV})..."
    docker stop ${APP_NAME}-${CURRENT_ENV} || true
    docker rm ${APP_NAME}-${CURRENT_ENV} || true
fi

# 7. Dọn rác
docker image prune -f

echo "================================================="
echo "🎉 Deploy Zero-Downtime thành công cho ${APP_NAME}!"
echo "================================================="
