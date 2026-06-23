// vars/dockerDeployPipeline.groovy
import com.mycompany.devops.DockerRunner

def call(Map config = [:]) {
    def imageName = config.imageName
    def ipServer = config.ipServer
    
    // Default values if not provided
    def agentLabel = config.agentLabel ?: 'jenkins-agent'
    def serverSshDeploy = config.serverSshDeploy ?: 'server-ssh-key'
    def dockerHubCredsId = config.dockerHubCredsId ?: 'dockerhub-creds'
    def discordWebhookId = config.discordWebhookId ?: 'discord-webhook-url'
    
    // Custom configurations for deploy script
    def appName = config.appName ?: (env.APP_NAME ?: imageName)
    def baoSecretPath = config.baoSecretPath ?: (env.BAO_SECRET_PATH ?: "${appName}/dev")
    def baoSecretVersion = config.baoSecretVersion ?: (env.BAO_SECRET_VERSION ?: '3')
    def bluePort = config.bluePort ?: (env.BLUE_PORT ?: '8080')
    def greenPort = config.greenPort ?: (env.GREEN_PORT ?: '8081')

    // Khởi tạo đối tượng DockerRunner từ thư mục src/
    DockerRunner docker = new DockerRunner(this)

    pipeline {
        agent {
            label agentLabel
        }
        environment {
            DOCKER_BUILDKIT = '1'
            IMAGE_NAME = "${imageName}"
            IMAGE_TAG = "${env.BUILD_NUMBER}"
            SERVER_SSH_DEPLOY = "${serverSshDeploy}"
            IP_SERVER = "${ipServer}"
            BAO_ADDR  = credentials('BAO_ADDR')
            BAO_TOKEN = credentials('BAO_TOKEN')
            
            // Env vars for deploy.sh
            APP_NAME = "${appName}"
            BAO_SECRET_PATH = "${baoSecretPath}"
            BAO_SECRET_VERSION = "${baoSecretVersion}"
            BLUE_PORT = "${bluePort}"
            GREEN_PORT = "${greenPort}"
        }

        stages {
            stage('Checkout') {
                steps {
                    script {
                        try {
                            checkout scm
                        } catch (Exception e) {
                            echo "Note: 'checkout scm' is only available when using Multibranch Pipeline or Pipeline script from SCM. Skipping checkout: ${e.message}"
                        }
                    }
                }
            }

            stage('Build Image') {
                steps {
                    script {
                        // Gọi logic từ src/
                        docker.buildImage(env.IMAGE_NAME, env.IMAGE_TAG)
                    }
                }
            }

            stage('Push to Registry') {
                steps {
                    script {
                        // Gọi logic từ src/
                        docker.pushImage(env.IMAGE_NAME, env.IMAGE_TAG, dockerHubCredsId)
                    }
                }
            }

            stage('Deploy to Server') {
                steps {
                    script {
                        // 1. Lấy script deploy từ thư mục resources/scripts/
                        def deployScriptContent = libraryResource('scripts/deploy.sh')
                        writeFile file: 'deploy.sh', text: deployScriptContent
                        
                        withCredentials([usernamePassword(credentialsId: dockerHubCredsId, passwordVariable: 'DOCKER_PASSWORD', usernameVariable: 'DOCKER_USERNAME')]) {
                            sshagent(credentials: [serverSshDeploy]) {
                                // 2. Copy script qua server và chạy script
                                sh "scp -o StrictHostKeyChecking=no deploy.sh \$IP_SERVER:/tmp/deploy.sh"
                                
                                sh """
                                ssh -o StrictHostKeyChecking=no \$IP_SERVER \\
                                    "APP_NAME='\$APP_NAME' \\
                                     BAO_SECRET_PATH='\$BAO_SECRET_PATH' \\
                                     BAO_SECRET_VERSION='\$BAO_SECRET_VERSION' \\
                                     BLUE_PORT='\$BLUE_PORT' \\
                                     GREEN_PORT='\$GREEN_PORT' \\
                                     BAO_ADDR='\$BAO_ADDR' \\
                                     BAO_TOKEN='\$BAO_TOKEN' \\
                                     DOCKER_USERNAME='\$DOCKER_USERNAME' \\
                                     DOCKER_PASSWORD='\$DOCKER_PASSWORD' \\
                                     bash /tmp/deploy.sh \$IMAGE_NAME \$IMAGE_TAG"
                                """
                            }
                        }
                    }
                }
            }
        }

        post {
            always {
                script {
                    docker.cleanupImages(env.IMAGE_NAME, env.IMAGE_TAG)
                }
            }
            success {
                script {
                    def commitMsg = "N/A"
                    def commitAuthor = "N/A"
                    try {
                        commitMsg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
                        commitAuthor = sh(script: 'git log -1 --pretty=%an', returnStdout: true).trim()
                        commitMsg = commitMsg.replace('"', '\\"').replace('\n', '\\n')
                    } catch (Exception e) {
                        echo "Failed to get git commit info: ${e.message}"
                    }
                    def currentTime = new Date().format("yyyy-MM-dd HH:mm:ss")
                    
                    withCredentials([string(credentialsId: discordWebhookId, variable: 'DISCORD_WEBHOOK')]) {
                        sh """
                        curl -H "Content-Type: application/json" -X POST -d '{
                            "embeds": [{
                                "title": "✅ Triển khai thành công (Zero-Downtime)",
                                "description": "Dự án **${IMAGE_NAME}** đã được cập nhật thành công lên server mà không bị gián đoạn hoạt động! 🚀",
                                "color": 3066993,
                                "fields": [
                                    { "name": "Build Number", "value": "#${env.BUILD_NUMBER}", "inline": true },
                                    { "name": "Docker Tag", "value": "${IMAGE_TAG}", "inline": true },
                                    { "name": "Commit Author", "value": "${commitAuthor}", "inline": true },
                                    { "name": "Commit Message", "value": "${commitMsg}", "inline": false }
                                ],
                                "footer": { "text": "Jenkins Pipeline • ${currentTime}" }
                            }]
                        }' \$DISCORD_WEBHOOK
                        """
                    }
                }
            }
            failure {
                script {
                    def commitMsg = "N/A"
                    def commitAuthor = "N/A"
                    try {
                        commitMsg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
                        commitAuthor = sh(script: 'git log -1 --pretty=%an', returnStdout: true).trim()
                        commitMsg = commitMsg.replace('"', '\\"').replace('\n', '\\n')
                    } catch (Exception e) {
                        echo "Failed to get git commit info: ${e.message}"
                    }
                    def currentTime = new Date().format("yyyy-MM-dd HH:mm:ss")
                    
                    withCredentials([string(credentialsId: discordWebhookId, variable: 'DISCORD_WEBHOOK')]) {
                        sh """
                        curl -H "Content-Type: application/json" -X POST -d '{
                            "embeds": [{
                                "title": "❌ Triển khai thất bại",
                                "description": "Quá trình CI/CD dự án **${IMAGE_NAME}** gặp lỗi nghiêm trọng. Vui lòng kiểm tra lại console log của Jenkins!",
                                "color": 15158332,
                                "fields": [
                                    { "name": "Build Number", "value": "#${env.BUILD_NUMBER}", "inline": true },
                                    { "name": "Docker Tag", "value": "${IMAGE_TAG}", "inline": true },
                                    { "name": "Commit Author", "value": "${commitAuthor}", "inline": true },
                                    { "name": "Commit Message", "value": "${commitMsg}", "inline": false }
                                ],
                                "footer": { "text": "Jenkins Pipeline • ${currentTime}" }
                            }]
                        }' \$DISCORD_WEBHOOK
                        """
                    }
                }
            }
        }
    }
}
