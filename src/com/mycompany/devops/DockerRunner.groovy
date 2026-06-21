package com.mycompany.devops

class DockerRunner implements Serializable {
    def script 

    DockerRunner(def script) {
        this.script = script
    }

    void buildImage(String imageName, String imageTag) {
        script.echo "Pulling latest image for cache..."
        script.sh "docker pull ${imageName}:latest || true"
        
        script.echo "Bắt đầu build image: ${imageName}:${imageTag}..."
        
        script.sh """
        DOCKER_BUILDKIT=1 docker build \\
            --build-arg BUILDKIT_INLINE_CACHE=1 \\
            --cache-from ${imageName}:latest \\
            -t ${imageName}:latest \\
            -t ${imageName}:${imageTag} .
        """
    }

    void pushImage(String imageName, String imageTag, String credsId) {
        script.withCredentials([script.usernamePassword(credentialsId: credsId, passwordVariable: 'DOCKER_PASSWORD', usernameVariable: 'DOCKER_USERNAME')]) {
            script.sh 'echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin'
            
            script.echo "Pushing images to registry..."
            script.sh "docker push ${imageName}:latest"
            script.sh "docker push ${imageName}:${imageTag}"
            
            script.echo "Logging out from Docker Hub..."
            script.sh "docker logout"
        }
    }
    
    void cleanupImages(String imageName, String imageTag) {
        script.echo "Cleaning up local Docker images on Jenkins..."
        script.sh "docker rmi ${imageName}:latest ${imageName}:${imageTag} || true"
        script.sh "docker image prune -f --filter 'until=24h' || true"
    }
}
