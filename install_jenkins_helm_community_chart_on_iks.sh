#!/bin/bash

export IKS_REGION=${IKS_REGION:-"<target_region>""}
export IKS_ACCOUNT=${IKS_ACCOUNT:-"<your_account_id>"}
export IKS_CLUSTER=${IKS_CLUSTER:-"<your_cluster_name>"}

# Prevent the bx CLI to check for version interactively as this is a headless script
bx config --check-version=false

# This assume that you are connected on IBM Bluemix and have a IKS cluster up & running
# bx login --sso

# Target the appropriate cluster (limited to Kubernetes 1.10 version cluster for now):
bx target -r $IKS_REGION -c $IKS_ACCOUNT
bx cs clusters
eval $(bx cs cluster-config --export $IKS_CLUSTER)

# Ensure the jenkins namespace is there (can be any other namespace that you want to)
kubectl create namespace jenkins

# Ensure helm is there (note: helm releases are there: https://github.com/helm/helm/releases)
helm init --wait
helm version

# Configure helm with IBM repository (https://console.bluemix.net/docs/containers/cs_integrations.html#helm)
helm repo add ibm https://registry.bluemix.net/helm/ibm
helm repo add ibm-charts https://registry.bluemix.net/helm/ibm-charts

# Update the helm repo local information
helm repo update

# Install IBM Blockstorage to overcome file storage issue (https://console.bluemix.net/docs/containers/cs_troubleshoot_storage.html#nonroot)
# https://console.bluemix.net/docs/containers/cs_storage_block.html#install_block
helm ls | grep ibmcloud-block-storage-plugin
if [ "$?" == "0" ]; then
    echo "Blockstorage already installed"
else 
    helm install ibm/ibmcloud-block-storage-plugin --name ibmcloud-block-storage-plugin --wait
    kubectl get pod -n kube-system | grep block
    kubectl get storageclasses | grep block
fi

# If the k8s cluster has ingress service (standard plan), overrid/define some configuration values to have the appropriate entries to manage ingress exposure for Jenkins UI
JENKINS_HOSTNAME=${JENKINS_HOSTNAME:-"cmt-jenkins-readme"}
INGRESS_SUBDOMAIN=$(bx cs cluster-get -s $IKS_CLUSTER | grep -i "Ingress subdomain:" | awk '{print $3;}')
INGRESS_SECRET=$(bx cs cluster-get -s $IKS_CLUSTER | grep -i "Ingress secret:" | awk '{print $3;}')
echo "nameOverride: $JENKINS_HOSTNAME" > cmt-jenkins-values.yaml
echo "Master:" >> cmt-jenkins-values.yaml
echo "  ServiceType: ClusterIP" >> cmt-jenkins-values.yaml
echo "  HostName: $JENKINS_HOSTNAME.$INGRESS_SUBDOMAIN" >> cmt-jenkins-values.yaml
echo "  Ingress:" >> cmt-jenkins-values.yaml
echo "    Annotations:" >> cmt-jenkins-values.yaml
echo "      ingress.bluemix.net/redirect-to-https: \"True\"" >> cmt-jenkins-values.yaml
echo "    TLS:" >> cmt-jenkins-values.yaml
echo "      - secretName: $INGRESS_SECRET" >> cmt-jenkins-values.yaml
echo "        hosts:" >> cmt-jenkins-values.yaml
echo "          - $JENKINS_HOSTNAME.$INGRESS_SUBDOMAIN" >> cmt-jenkins-values.yaml

#In case of no Ingress, only `nameOverride` would be sufficient:
#echo "nameOverride: $JENKINS_HOSTNAME" > cmt-jenkins-values.yaml
#echo "Master:" >> cmt-jenkins-values.yaml

# Plugins to install:
# - latest version of jenkins community chart default install plugins
# To install the latest version of the default plugins plus the one for IKS config,
# complete cmt-jenkins-values.yaml with:
echo "  InstallPlugins:" >> cmt-jenkins-values.yaml
echo "    - kubernetes:latest" >> cmt-jenkins-values.yaml
echo "    - workflow-job:latest" >> cmt-jenkins-values.yaml
echo "    - workflow-aggregator:latest" >> cmt-jenkins-values.yaml
echo "    - credentials-binding:latest" >> cmt-jenkins-values.yaml
echo "    - git:latest" >> cmt-jenkins-values.yaml
# for IBM Cloud Object Storage usage with S3 plugin
echo "    - s3:latest"  >> cmt-jenkins-values.yaml

# RBAC must be enabled for Jenkins deployment on IBM Cloud/IKS, complete the cmt-jenkins-values.yaml
echo "rbac:" >> cmt-jenkins-values.yaml
echo "  install: true" >> cmt-jenkins-values.yaml

#  Blockstorage configuration
# To let helm installation perform the creation of the Blockstorage, complete the cmt-jenkins-values.yaml
echo "Persistence:" >> cmt-jenkins-values.yaml
echo "  StorageClass: ibmc-block-gold" >> cmt-jenkins-values.yaml

#An alternative would be to choose/specifiy the default storage class using:
#```
#kubectl patch storageclass ibmc-file-bronze -p '{"metadata": {"annotations" {"storageclass.kubernetes.io/is-default-class":"false"}}}'
# you can also choose ibmc-block-silver or ibmc-block-gold for better IOPS
#kubectl patch storageclass ibmc-block-bronze -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
#```

# To use Cloud Object Storage using the Jenkins S3 plugin, we need a couple of adjustement:
# - define the COS endpoints as a configuration file
# - force the startup of Jenkins to use this overriden endpoints
# First, create a ConfigMap instance
cat > cos_endpoints_configmap.yaml <<'EOT'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cos-endpoints-configmap
data:
  endpoints.json: |-
    {
    "partitions": [
        {
        "defaults": {
            "hostname": "{service}.{region}.{dnsSuffix}",
            "protocols": [
            "https"
            ],
            "signatureVersions": [
            "v4"
            ]
        },
        "dnsSuffix": "objectstorage.softlayer.net",
        "partition": "ibmcloud",
        "partitionName": "IBM Cloud",
        "regionRegex": "^(us|eu|ap)\\-\\w+\\-\\d+$",
        "regions": {
            "us-geo": {
            "description": "US cross-region "
            },
            "eu-geo": {
            "description": "EU cross-region "
            },
            "ap-geo": {
            "description": "AP cross-region "
            },
            "jp-tok": {
            "description": "AP North "
            },
            "eu-de": {
            "description": "Germany "
            },
            "eu-gb": {
            "description": "United Kingdom "
            },
            "us-east": {
            "description": "US East "
            },
            "us-south": {
            "description": "US South "
            }
        },
        "services": {
            "s3": {
            "defaults": {
                "protocols": [
                "http",
                "https"
                ],
                "signatureVersions": [
                "s3v4"
                ]
            },
            "endpoints": {
                "us-geo": {
                "hostname": "s3-api.us-geo.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                },
                "eu-geo": {
                "hostname": "s3-api.eu-geo.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                },
                "ap-geo": {
                "hostname": "s3-api.ap-geo.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                },
                "jp-tok": {
                "hostname": "s3.jp-tok.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                },
                "eu-de": {
                "hostname": "s3.eu-de.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                },
                "eu-gb": {
                "hostname": "s3.eu-gb.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                },
                "us-east": {
                "hostname": "s3.us-east.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                },
                "us-south": {
                "hostname": "s3.us-south.objectstorage.softlayer.net",
                "signatureVersions": [
                    "s3",
                    "s3v4"
                ]
                }
            }
            }
        }
        }
    ],
    "version": 3
    }
EOT
kubectl apply --namespace jenkins -f cos_endpoints_configmap.yaml

# Complete the values yaml file to define JVM option for Jenkins server
echo "Master:" > cmt-jenkins-cos-values.yaml
echo "  JavaOpts: \"-Xbootclasspath/a:/var/ibm_cos -Dhudson.plugins.s3.DEFAULT_AMAZON_S3_REGION=us-south\""   >> cmt-jenkins-cos-values.yaml

# Reference this configmap as volume in the jenkins
echo "Persistence:" >> cmt-jenkins-cos-values.yaml
echo "  volumes:" >> cmt-jenkins-cos-values.yaml
echo "    - name: ibm-cos-endpoints" >> cmt-jenkins-cos-values.yaml
echo "      configMap:" >> cmt-jenkins-cos-values.yaml
echo "        name: cos-endpoints-configmap" >> cmt-jenkins-cos-values.yaml
echo "        items:" >> cmt-jenkins-cos-values.yaml
echo "          - key: endpoints.json" >> cmt-jenkins-cos-values.yaml
echo "            path: com/amazonaws/partitions/override/endpoints.json" >> cmt-jenkins-cos-values.yaml
echo "  mounts:" >> cmt-jenkins-cos-values.yaml
echo "    - mountPath: /var/ibm_cos" >> cmt-jenkins-cos-values.yaml
echo "      name: ibm-cos-endpoints" >> cmt-jenkins-cos-values.yaml
echo "      readOnly: true" >> cmt-jenkins-cos-values.yaml

# To use IBM Cloud Object Storage with S3 plugin, you will need to configure a S3 profile (Manage Jenkins >> Global System)
# The access key and secret for the IBM COS service needs to be created with https://console.bluemix.net/docs/services/cloud-object-storage/iam/service-credentials.html#service-credentials
# Do not forget to specify the following in the Add Inline Configuration Parameters (Optional) field: {"HMAC":true}
# Note: the hmac keys are not obtainable other that using the web ui (no bx iam/bx cos CLI commands available)

# Sample jobs/pipeline related
# Define the initial PodTemplate to build NodeJS
# Reminder: only pipeline job are really supported by Kubernetes Plugin
# https://issues.jenkins-ci.org/browse/JENKINS-47055?focusedCommentId=327312&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-327312
cat > cmt-jenkins-sample-values.yaml <<'EOT'
Master:
  InitScripts:
    - |
        // Creation of credentials entries (w/o real values) for Sample
        import com.cloudbees.plugins.credentials.impl.*;
        import com.cloudbees.plugins.credentials.*;
        import com.cloudbees.plugins.credentials.domains.*;
        import org.jenkinsci.plugins.plaincredentials.impl.*;
        import hudson.util.*;

        Credentials c = (Credentials) new UsernamePasswordCredentialsImpl(CredentialsScope.GLOBAL,"ibm-cr-credentials", "IBM Container Registry Credentials used for sample", "token", "");
        SystemCredentialsProvider.getInstance().getStore().addCredentials(Domain.global(), c)

        c = (Credentials) new StringCredentialsImpl(CredentialsScope.GLOBAL,"ibmcloud-apikey", "IBM Cloud apikey for ibmcloud/bx access used for sample", Secret.fromString(""));
        SystemCredentialsProvider.getInstance().getStore().addCredentials(Domain.global(), c)

    - |
        // Creation of PODTemplates for Sample
        import hudson.model.*
        import jenkins.model.*
        import org.csanchez.jenkins.plugins.kubernetes.*
        import org.csanchez.jenkins.plugins.kubernetes.model.*
        import org.csanchez.jenkins.plugins.kubernetes.volumes.*

        def instance = Jenkins.getInstance()
        def kc
        try {
        println("Configuring k8s")
        kc = Jenkins.instance.clouds.get(0)
        println "cloud found: ${Jenkins.instance.clouds}"

        // Define a PODTemplate iheriting the default one and add a container for NodeJS build
        def podTemplate = new PodTemplate()
        podTemplate.setName("NodeJS Slave")
        podTemplate.setLabel("nodejs_slave")

        def containerTemplates = []
        // Add NodeJS 
        ContainerTemplate ct = new ContainerTemplate("nodejs", "node:6-alpine");
        ct.setPrivileged(true);
        ct.setTtyEnabled(true);
        // ct.setResourceRequestCpu("1000m")
        // ct.setResourceLimitCpu("2000m")
        ct.setResourceRequestMemory("1Gi")
        ct.setResourceLimitMemory("2Gi")
        containerTemplates.add(ct)
        println "added ${ct.name}"

        // Add Docker 
        ct = new ContainerTemplate("docker", "docker:stable");
        ct.setPrivileged(true);
        ct.setTtyEnabled(true);
        // ct.setResourceRequestCpu("1000m")
        // ct.setResourceLimitCpu("2000m")
        ct.setResourceRequestMemory("1Gi")
        ct.setResourceLimitMemory("2Gi")
        containerTemplates.add(ct)
        println "added ${ct.name}"

        // Add an image supporting Bluemix CLI
        ct = new ContainerTemplate("ibmcloud", "ibmcom/ibm-cloud-developer-tools-amd64");
        ct.setPrivileged(true);
        ct.setTtyEnabled(true);
        ct.getEnvVars().add(new KeyValueEnvVar("HOME", "/root"));
        containerTemplates.add(ct)
        println "added ${ct.name}"
          
        HostPathVolume volume = new HostPathVolume("/var/run/docker.sock", "/var/run/docker.sock")
        podTemplate.getVolumes().add(volume);

        podTemplate.setContainers(containerTemplates);
        
        println "added ${podTemplate.getName()}"
        kc.templates << podTemplate
        
        kc = null
        println("Configuring k8s completed")
        println("Saving changes...")
        instance.save()
        }
        finally {
        kc = null
        }
EOT

# Define a sample Job to use the tutorial NodeJS and React sample
# https://jenkins.io/doc/tutorials/build-a-node-js-and-react-app-with-npm/
# the push to the private container registry and the deployment of the sample app to the IBM Cloud target cluster
# expects some pre-requisistes:
#
# 1) A credential called 'ibm-cr-credentials' being a Jenkins username/password credentials with username
#    being "token" and password being the token's value corresponding to a token for the target IBM Container Registry:
#    $ bx cr token-add --non-expiring --readwrite --description "jenkins sample"
#    or if an existing one exists:
#    $ bx cr tokens (to find the list of tokens)
#    $ bx cr token-get <cr token id>
#
# 2) the private container registry is expected to have a namespace named 'jenkinssample'
#    $ bx cr namespace-add jenkinssample
#
# 3) A credential called 'ibmcloud-apikey' being provided as a Jenkins secret text credentials that contains the apiKey
#    used to login to the target cluster for the sample application deployment.
#    Note: the cluster configuration for kubectl CLI is obtained from the bx CLI that needs to login using an apikey
#    $ bx iam api-keys
#    $ bx iam api-key-create 
cat >> cmt-jenkins-sample-values.yaml <<'EOT'
  Jobs:
    sample: |-
      <flow-definition plugin="workflow-job@2.25">
        <actions>
          <org.jenkinsci.plugins.pipeline.modeldefinition.actions.DeclarativeJobAction plugin="pipeline-model-definition@1.3.2"/>
          <org.jenkinsci.plugins.pipeline.modeldefinition.actions.DeclarativeJobPropertyTrackerAction plugin="pipeline-model-definition@1.3.2">
            <jobProperties/>
            <triggers/>
            <parameters/>
            <options/>
          </org.jenkinsci.plugins.pipeline.modeldefinition.actions.DeclarativeJobPropertyTrackerAction>
        </actions>
        <description></description>
        <keepDependencies>false</keepDependencies>
        <properties/>
        <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps@2.59">
          <script>pipeline {
        agent {
          kubernetes {
          label &apos;nodejs_slave&apos;
          }
        }
        environment {
          CI = &apos;true&apos;
          BLUEMIX_API_KEY = credentials(&apos;ibmcloud-apikey&apos;)
          IBM_CR_TOKEN = credentials(&apos;ibm-cr-credentials&apos;)
          // TARGET CLUSTER
          K8S_CLUSTER = &quot;<your_cluster_name>&quot;
          K8S_NAMESPACE = &quot;default&quot;
        }
        stages {
          stage(&apos;Preparation&apos;) {
            steps {
              git &apos;https://github.com/jenkins-docs/simple-node-js-react-npm-app&apos;
            }
          }
          stage(&apos;Build&apos;) {
              environment {
              // get git commit from Jenkins
              GIT_COMMIT = sh(returnStdout: true, script: &apos;git rev-parse HEAD&apos;).trim()
              GIT_BRANCH = &apos;master&apos;
              GIT_REPO = &apos;GIT_REPO_URL_PLACEHOLDER&apos;
              }
              steps {
                container(&quot;nodejs&quot;) {
                  sh &apos;npm install&apos;
                }
              }
          }
          stage(&apos;Test&apos;) {
            steps {
              container(&quot;nodejs&quot;) {
              sh &apos;./jenkins/scripts/test.sh&apos;
              }
            }
          }
          stage(&apos;Build Docker Image&apos;) {
            steps {
              container(&quot;docker&quot;) {
                script {
                  // Naive Dockerfile for a React app
                  writeFile file: &apos;Dockerfile&apos;, text: &apos;FROM node:6-alpine\nCOPY . .\nEXPOSE 3000\nCMD [&quot;npm&quot;, &quot;start&quot;]&apos;
      
                  // Build and Push the Docker image to the private registry
                  docker.withRegistry(&apos;https://registry.ng.bluemix.net&apos;, &apos;ibm-cr-credentials&apos;) {
                  // change jenkinssample namespace if needed  
                  def customImage = docker.build(&quot;jenkinssample/sample-nodejs-react:${env.BUILD_NUMBER}&quot;)
                  customImage.push()
                  }
                }
              }
            }
          }
          stage(&apos;Deploy application&apos;) {
            steps {
              container(&apos;ibmcloud&apos;) {
                  script {
                      // create pod file
                      writeFile file: &apos;sample_pod.yaml&apos;, text: &apos;&apos;&apos;apiVersion: v1
      kind: Pod
      metadata:
        name: sample-nodejs-react
        labels:
          name: sample-nodejs-react
      spec:
        imagePullSecrets:
        - name: ibm-cr-registry-secret
        hostname: sample-nodejs-react
        containers:
        - name: sample-nodejs-react
          image: registry.ng.bluemix.net/jenkinssample/sample-nodejs-react:&apos;&apos;&apos; + env.BUILD_NUMBER + &apos;&apos;&apos;
          ports:
          - containerPort: 3000
      &apos;&apos;&apos;
      
                      // create service file
                      writeFile file: &apos;sample_service.yaml&apos;, text: &apos;&apos;&apos;apiVersion: v1
      kind: Service
      metadata:
        name: sample-nodejs-react
      spec:
        type: NodePort
        ports:
        - port: 3000
        selector:
          name: sample-nodejs-react
      &apos;&apos;&apos;
                  }
      
                  sh &apos;&apos;&apos;
                  ibmcloud config --check-version=false
                  # API to access the target cluster
                  ibmcloud api https://api.ng.bluemix.net
                  # Target region
                  ibmcloud target -r us-south
                  ibmcloud login
      
                  ibmcloud cs clusters
      
                  eval $(ibmcloud cs cluster-config --export $K8S_CLUSTER)
      
                  kubectl get namespaces
      
                  kubectl --namespace $K8S_NAMESPACE --ignore-not-found=true delete secret ibm-cr-registry-secret
                  kubectl --namespace $K8S_NAMESPACE create secret docker-registry ibm-cr-registry-secret --docker-server=registry.ng.bluemix.net --docker-username=&quot;$IBM_CR_TOKEN_USR&quot; --docker-password=&quot;$IBM_CR_TOKEN_PSW&quot; --docker-email=a@b.c
      
                  cat sample_pod.yaml
                  kubectl apply -f sample_pod.yaml --namespace $K8S_NAMESPACE
      
                  cat sample_service.yaml
                  kubectl apply -f sample_service.yaml --namespace $K8S_NAMESPACE
      
                  # Identity the ip:port to access react
                  APP_IP=$(bx cs workers --cluster $K8S_CLUSTER -s | tail -1 | awk &apos;{print $2;}&apos;  | tr -d &apos;\n&apos;)
                  APP_PORT=$(kubectl get service sample-nodejs-react --namespace $K8S_NAMESPACE --no-headers | awk &apos;{print $5;}&apos; | awk -F&apos;[:/]&apos; &apos;{print $2;}&apos;)
                  echo &quot;App is accessible there: http://$APP_IP:$APP_PORT&quot;
      
                  &apos;&apos;&apos;
              }
            }
          }
        }
      }</script>
          <sandbox>true</sandbox>
        </definition>
        <triggers/>
        <disabled>false</disabled>
      </flow-definition>
EOT


# Install the Jenkins community-chart
echo "Doing installation: $ helm install --name $JENKINS_HOSTNAME stable/jenkins -f cmt-jenkins-values.yaml -f cmt-jenkins-cos-values.yaml -f cmt-jenkins-sample-values.yaml --namespace jenkins --wait --timeout 600"
helm install --name $JENKINS_HOSTNAME stable/jenkins -f cmt-jenkins-values.yaml -f cmt-jenkins-cos-values.yaml -f cmt-jenkins-sample-values.yaml --namespace jenkins --wait --timeout 600
