package com.example.demo;

import io.fabric8.kubernetes.api.model.ConfigMap;
import io.fabric8.kubernetes.api.model.ConfigMapBuilder;
import io.fabric8.kubernetes.api.model.Quantity;
import io.fabric8.kubernetes.api.model.batch.v1.Job;
import io.fabric8.kubernetes.api.model.batch.v1.JobBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import org.springframework.stereotype.Service;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

@Service
public class ExecutionService {

    private static final String NAMESPACE = "default";

    // Cap on how much output we return (defends against endless-output attacks)
    private static final int MAX_OUTPUT_CHARS = 10_000;

    private final KubernetesClient client;

    public ExecutionService(KubernetesClient client) {
        this.client = client;
    }

    public String runCode(String code) {
        String id = UUID.randomUUID().toString().substring(0, 8);
        String jobName = "exec-" + id;
        String configMapName = "code-" + id;

        try {
            // 1. Put the user's code into a ConfigMap as "Main.java"
            ConfigMap configMap = new ConfigMapBuilder()
                    .withNewMetadata()
                        .withName(configMapName)
                    .endMetadata()
                    .withData(Map.of("Main.java", code))
                    .build();
            client.configMaps().inNamespace(NAMESPACE).resource(configMap).create();

            // 2. Create a HARDENED Job
            Job job = new JobBuilder()
                    .withNewMetadata()
                        .withName(jobName)
                    .endMetadata()
                    .withNewSpec()
                        .withBackoffLimit(0)
                        .withActiveDeadlineSeconds(15L)   // TIMEOUT: kill after 15s no matter what
                        .withTtlSecondsAfterFinished(30)  // auto-clean the Job object shortly after
                        .withNewTemplate()
                            .withNewMetadata()
                                .addToLabels("role", "code-execution")
                            .endMetadata()
                            .withNewSpec()
                                .withRestartPolicy("Never")
                                .withAutomountServiceAccountToken(false)  // execution pod gets NO API access
                                // Pod-level security: run as a fixed non-root user
                                .withNewSecurityContext()
                                    .withRunAsNonRoot(true)
                                    .withRunAsUser(1000L)
                                    .withRunAsGroup(1000L)
                                    .withFsGroup(1000L)
                                .endSecurityContext()
                                .addNewContainer()
                                    .withName("runner")
                                    .withImage("eclipse-temurin:21-jdk")
                                    .withWorkingDir("/work")
                                    .withCommand("sh", "-c",
                                            "javac -d /work /code/Main.java && java -cp /work Main")
                                    // Resource limits: memory cap + CPU cap
                                    .withNewResources()
                                        .addToRequests("memory", new Quantity("128Mi"))
                                        .addToRequests("cpu", new Quantity("250m"))
                                        .addToLimits("memory", new Quantity("256Mi"))
                                        .addToLimits("cpu", new Quantity("500m"))
                                    .endResources()
                                    // Container-level security hardening
                                    .withNewSecurityContext()
                                        .withAllowPrivilegeEscalation(false)
                                        .withReadOnlyRootFilesystem(true)
                                        .withNewCapabilities()
                                            .withDrop("ALL")
                                        .endCapabilities()
                                    .endSecurityContext()
                                    .addNewVolumeMount()
                                        .withName("code-volume")
                                        .withMountPath("/code")
                                        .withReadOnly(true)
                                    .endVolumeMount()
                                    .addNewVolumeMount()
                                        .withName("work-volume")
                                        .withMountPath("/work")
                                    .endVolumeMount()
                                .endContainer()
                                .addNewVolume()
                                    .withName("code-volume")
                                    .withNewConfigMap()
                                        .withName(configMapName)
                                    .endConfigMap()
                                .endVolume()
                                .addNewVolume()
                                    .withName("work-volume")
                                    .withNewEmptyDir()
                                        .withSizeLimit(new Quantity("32Mi")) // disk cap
                                    .endEmptyDir()
                                .endVolume()
                            .endSpec()
                        .endTemplate()
                    .endSpec()
                    .build();
            client.batch().v1().jobs().inNamespace(NAMESPACE).resource(job).create();

            // 3. Wait for completion — backstop timeout slightly longer than the Job deadline
            client.batch().v1().jobs().inNamespace(NAMESPACE).withName(jobName)
                    .waitUntilCondition(j -> j != null && j.getStatus() != null
                            && ((j.getStatus().getSucceeded() != null && j.getStatus().getSucceeded() > 0)
                             || (j.getStatus().getFailed() != null && j.getStatus().getFailed() > 0)),
                            25, TimeUnit.SECONDS);

            // 4. Read output, then TRUNCATE to the cap
            String output = client.batch().v1().jobs().inNamespace(NAMESPACE).withName(jobName).getLog();
            if (output == null || output.isBlank()) {
                return "(no output — the program may have timed out or been killed for exceeding limits)";
            }
            if (output.length() > MAX_OUTPUT_CHARS) {
                output = output.substring(0, MAX_OUTPUT_CHARS) + "\n...(output truncated)";
            }
            return output;

        } catch (Exception e) {
            return "Execution error: " + e.getMessage();
        } finally {
            // 5. Always clean up
            client.batch().v1().jobs().inNamespace(NAMESPACE).withName(jobName).delete();
            client.configMaps().inNamespace(NAMESPACE).withName(configMapName).delete();
        }
    }
}