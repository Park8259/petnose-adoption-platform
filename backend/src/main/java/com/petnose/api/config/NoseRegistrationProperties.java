package com.petnose.api.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;

@Getter
@Setter
@ConfigurationProperties(prefix = "nose")
public class NoseRegistrationProperties {

    private double duplicateThreshold = 0.65;
    private double reviewLowerBound = 0.60;
    private int referenceMinCount = 3;
    private int referenceMaxCount = 5;
    private double referenceConsistencyThreshold = 0.55;
    private String preprocessVersion = "rgb_resize224_bicubic_imagenet_l2_v1";
}
