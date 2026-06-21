# Hướng Dẫn Cấu Hình Jenkins Shared Library & Thiết Lập Job Pipeline

Tài liệu này hướng dẫn bạn từng bước cách thiết lập một Jenkins Shared Library vừa được tạo và cách cấu hình một Jenkins Job để sử dụng library đó.

> [!TIP]
> Jenkins Shared Library giúp bạn tái sử dụng cùng một logic pipeline (CI/CD) cho hàng chục hoặc hàng trăm dự án mà không cần phải copy/paste lại file `Jenkinsfile` quá dài dòng.

---

## Phần 1: Push Source Code Lên Git

1. Khởi tạo Git ở thư mục `c:\laragon\www\jenkins-shared-library` (nếu chưa có):
   ```bash
   cd c:/laragon/www/jenkins-shared-library
   git init
   git add .
   git commit -m "Init Jenkins Shared Library"
   ```
2. Đẩy (Push) thư mục này lên một repository mới trên GitHub, GitLab, hoặc Bitbucket (Ví dụ: `https://github.com/yourusername/jenkins-shared-library.git`).
   ```bash
   git remote add origin https://github.com/yourusername/jenkins-shared-library.git
   git push -u origin main
   ```

---

## Phần 2: Cấu Hình Shared Library trên Global Jenkins

Để Jenkins "hiểu" được hàm `@Library('my-shared-library') _` trong `Jenkinsfile`, bạn phải khai báo repo này trong cấu hình Jenkins.

1. Đăng nhập vào Jenkins Dashboard bằng quyền Admin.
2. Điều hướng tới: **Manage Jenkins** > **System** (hoặc Configure System đối với bản cũ).
3. Cuộn xuống phần **Global Pipeline Libraries**.
4. Bấm vào nút **Add** để thêm một library mới và điền như sau:
   - **Name**: `my-shared-library` *(Bắt buộc phải đúng tên này vì trong Jenkinsfile của dự án ta dùng @Library('my-shared-library'))*
   - **Default version**: `main` *(nhánh mặc định trên Git chứa code)*
   - **Load implicitly**: Tắt (Bỏ tick)
   - **Allow default version to be overridden**: Bật (Tick)
   - Trong phần **Retrieval method**:
     - Chọn **Modern SCM**.
     - Chọn tiếp **Git**.
     - **Project Repository**: Nhập link Git (Ví dụ: `https://github.com/yourusername/jenkins-shared-library.git`).
     - **Credentials**: Chọn Credentials có quyền đọc repository này (nếu repo là private).
5. Nhấn **Save** ở dưới cùng.

---

## Phần 3: Thiết Lập Pipeline Job Cho Dự Án (`orders`)

Bây giờ bạn cần tạo hoặc sửa đổi một Job trên Jenkins để chạy dự án Orders với Jenkinsfile siêu ngắn gọn vừa cập nhật.

1. Trở về màn hình Jenkins Dashboard.
2. Bấm **New Item** (Nếu đã có Job rồi thì vào Job đó chọn **Configure**):
   - Nhập tên job: Ví dụ `Orders-Service-Pipeline`
   - Chọn **Pipeline** và bấm **OK**.
3. Tại trang **Configure** của Job:
   - (Tùy chọn) Phần **General**: Có thể tick chọn `Discard old builds` hoặc các option phù hợp.
   - (Tùy chọn) Phần **Build Triggers**: Có thể cấu hình Webhooks như `GitHub hook trigger for GITScm polling` nếu muốn push code thì tự động chạy.
   - **Quan trọng - Phần Pipeline**:
     - Ở dropdown **Definition**, chọn: **Pipeline script from SCM**.
     - **SCM**: Chọn **Git**.
     - **Repository URL**: Nhập link Git của dự án `orders` (Ví dụ: `https://github.com/yourusername/orders-project.git`).
     - **Credentials**: Chọn credentials phù hợp nếu repo private.
     - **Branches to build**: `*/main` (hoặc nhánh nào bạn muốn build).
     - **Script Path**: Nhập `Jenkinsfile` *(Jenkins sẽ đọc nội dung file Jenkinsfile nằm ngay ngoài cùng dự án orders)*.
4. Bấm **Save**.

### 🚀 Chạy Thử
- Bấm **Build Now** trong Job.
- Jenkins sẽ làm 2 việc:
  1. Kéo mã nguồn dự án `orders`.
  2. Phát hiện câu lệnh `@Library('my-shared-library') _` trong `Jenkinsfile` -> Jenkins sẽ tiến hành kéo mã nguồn từ repo library về.
  3. Khởi chạy hàm `dockerDeployPipeline(...)` được khai báo trong thư mục `vars/` và thực thi toàn bộ luồng CI/CD như cấu hình.

> [!NOTE]
> Khi có dự án thứ 2 (ví dụ `payments`), bạn cũng chỉ việc tạo 1 job tương tự và thêm file Jenkinsfile chỉ với 4 dòng gọi cấu hình `dockerDeployPipeline(imageName: '...', ipServer: '...')` là xong. Toàn bộ logic build Docker, Push Hub, và Deploy sẽ được tái sử dụng.
