#version 460 core

out vec4 color;

in Vertex {
    vec4 outColor;
    vec2 outTexture;
    flat int textureIndex;
};

void main() {
    //color = vec4(1.0);
    color = outColor;
}
