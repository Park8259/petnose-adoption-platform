package com.petnose.api.controller;

import com.petnose.api.client.EmbedClient;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = DevController.class)
@ActiveProfiles("dev")
@TestPropertySource(properties = {
        "qdrant.host=localhost",
        "qdrant.port=6333",
        "qdrant.collection=test_collection",
        "qdrant.vector-dimension=2048",
        "qdrant.distance=Cosine"
})
class DevControllerProfileNoseProxyTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private EmbedClient embedClient;

    @Test
    void profileNosePreviewProxiesToPythonEmbedServiceOnly() throws Exception {
        Map<String, Object> upstreamResponse = new LinkedHashMap<>();
        upstreamResponse.put("extracted", true);
        upstreamResponse.put("crop_width", 224);
        upstreamResponse.put("crop_height", 224);
        upstreamResponse.put("failure_reason", null);
        when(embedClient.extractProfileNose(any(byte[].class), eq("profile.jpg"), eq(MediaType.IMAGE_JPEG_VALUE)))
                .thenReturn(upstreamResponse);

        MockMultipartFile profileImage = new MockMultipartFile(
                "profile_image",
                "profile.jpg",
                MediaType.IMAGE_JPEG_VALUE,
                new byte[]{1, 2, 3}
        );

        mockMvc.perform(multipart("/api/dev/profile-nose-preview").file(profileImage))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.extracted").value(true))
                .andExpect(jsonPath("$.crop_width").value(224))
                .andExpect(jsonPath("$.crop_height").value(224));

        verify(embedClient).extractProfileNose(any(byte[].class), eq("profile.jpg"), eq(MediaType.IMAGE_JPEG_VALUE));
        verifyNoMoreInteractions(embedClient);
    }

    @Test
    void profileNoseMatchProxiesToPythonEmbedServiceOnly() throws Exception {
        Map<String, Object> upstreamResponse = new LinkedHashMap<>();
        upstreamResponse.put("matched", true);
        upstreamResponse.put("similarity_score", 0.83);
        upstreamResponse.put("threshold_calibrated", false);
        upstreamResponse.put("failure_reason", null);
        when(embedClient.profileNoseMatch(
                any(byte[].class),
                eq("profile.jpg"),
                eq(MediaType.IMAGE_JPEG_VALUE),
                any(byte[].class),
                eq("nose.jpg"),
                eq(MediaType.IMAGE_JPEG_VALUE)
        )).thenReturn(upstreamResponse);

        MockMultipartFile profileImage = new MockMultipartFile(
                "profile_image",
                "profile.jpg",
                MediaType.IMAGE_JPEG_VALUE,
                new byte[]{1, 2, 3}
        );
        MockMultipartFile noseImage = new MockMultipartFile(
                "nose_image",
                "nose.jpg",
                MediaType.IMAGE_JPEG_VALUE,
                new byte[]{4, 5, 6}
        );

        mockMvc.perform(multipart("/api/dev/profile-nose-match")
                        .file(profileImage)
                        .file(noseImage))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.matched").value(true))
                .andExpect(jsonPath("$.similarity_score").value(0.83))
                .andExpect(jsonPath("$.threshold_calibrated").value(false));

        verify(embedClient).profileNoseMatch(
                any(byte[].class),
                eq("profile.jpg"),
                eq(MediaType.IMAGE_JPEG_VALUE),
                any(byte[].class),
                eq("nose.jpg"),
                eq(MediaType.IMAGE_JPEG_VALUE)
        );
        verifyNoMoreInteractions(embedClient);
    }
}
