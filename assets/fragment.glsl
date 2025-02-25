#version 460 core

out vec4 color;

layout (binding = 2) uniform sampler2DArray textureSampler1;

in Vertex {
    vec4 outColor;
    vec2 outTexture;
    flat int textureIndex;
};

void main() {
    float tex = texture(textureSampler1, vec3(outTexture, textureIndex)).r;
    float aaf = fwidth(tex);
    float alpha = smoothstep(0.45 - aaf, 0.45 + aaf, tex);

    color = vec4(outColor.r, outColor.g, outColor.b, alpha * outColor.a);
}
