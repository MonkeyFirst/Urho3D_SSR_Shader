#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"

varying vec2 vTexCoord;
varying vec2 vScreenPos;
varying vec3 vFarRay;
varying vec3 vViewFarRay;

#ifdef COMPILEPS
uniform vec2 cSSRHInvSize;
#endif
#line 14

#ifdef COMPILEVS

vec3 GetViewFarRaySS(vec2 ss) 
{
  vec4 cameraRay = vec4(ss.xy * vec2(2.0, 2.0) - vec2(1.0, 1.0), 1.0, 1.0);
  cameraRay = cameraRay * cProjInv;
  cameraRay.xyz = cameraRay.xyz / cameraRay.w;
  return cameraRay.xyz;
}

#endif

void VS()
{
    mat4 modelMatrix = iModelMatrix;
    vec3 worldPos = GetWorldPos(modelMatrix);
    gl_Position = GetClipPos(worldPos);
    vTexCoord = GetQuadTexCoord(gl_Position);
    vScreenPos = GetScreenPosPreDiv(gl_Position);
    vFarRay = GetFarRay(gl_Position);
    vViewFarRay = GetViewFarRaySS(vScreenPos);
}

#ifdef COMPILEPS

vec3 GetViewFarRaySSPS(vec2 ss) 
{
  vec4 cameraRay = vec4(ss.xy * vec2(2.0,2.0) - vec2(1.0, 1.0), 1.0, 1.0);
  cameraRay = cameraRay * cProjInvPS;
  cameraRay.xyz = cameraRay.xyz / cameraRay.w;
  return cameraRay.xyz;
}

vec2 GetScreenPosPreDivPS(vec4 clipPos)
{
    return vec2(
        clipPos.x / clipPos.w * cGBufferOffsetsPS.z + cGBufferOffsetsPS.x,
        clipPos.y / clipPos.w * cGBufferOffsetsPS.w + cGBufferOffsetsPS.y);
}

vec3 GetViewPosition(vec2 ssPos, float depth)
{
    // eye_z = depth(0=camera .. 1=far) * far
    float eye_z = depth * cFrustumSizePS.z;
    return vec3(ssPos * cProjInfo.xy + cProjInfo.zw, 1.0) * eye_z;
}

const float step = 0.5;
const float minRayStep = 0.1;
const float maxSteps = 32;
const int numBinarySearchSteps = 16;

vec3 fresnelSchlick(float cosTheta, vec3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

//HASH
#define Scale vec3(.9, .9, .9)
#define K 19.19

vec3 hash(vec3 a)
{
    a = fract(a * Scale);
    a += dot(a, a.yxz + K);
    return fract((a.xxy + a.yxx) * a.zyx);
}

vec3 BinarySearch(inout vec3 dir, inout vec3 hitCoord, inout float dDepth)
{
    float depth;
    vec4 projectedCoord;

    for(int i = 0; i < numBinarySearchSteps; i++)
    {
        projectedCoord = vec4(hitCoord, 1.0) * cProjPS;
        //projectedCoord.xy /= projectedCoord.w;
        //projectedCoord.xy = projectedCoord.xy * 0.5 + 0.5;
        projectedCoord.xy = GetScreenPosPreDivPS(projectedCoord);
 
        #ifdef HWDEPTH
            float depth = ReconstructDepth(texture2D(sDepthBuffer, projectedCoord.xy).r);
        #else
            float depth = DecodeDepth(texture2D(sDepthBuffer, projectedCoord.xy).rgb);
        #endif
        
        //vec3 viewPos = GetViewPosition(projectedCoord.xy, depth);
        vec3 viewPos = vViewFarRay * -depth;
        dDepth = hitCoord.z - viewPos.z;

        dir *= 0.5;
        if(dDepth > 0.0)
            hitCoord += dir;
        else
            hitCoord -= dir; 
               
    }

    projectedCoord = vec4(hitCoord, 1.0) * cProjPS;
    //projectedCoord.xy /= projectedCoord.w;
    //projectedCoord.xy = projectedCoord.xy * 0.5 + 0.5;
    projectedCoord.xy = GetScreenPosPreDivPS(projectedCoord);
 
    return vec3(projectedCoord.xy, -depth);
}

vec4 RayMarch(vec3 dir, inout vec3 hitCoord, inout float dDepth)
{
    dir *= step;
    float depth;
    vec4 projectedCoord;

    for(int i = 0; i < maxSteps; i++)
    {
        hitCoord += dir;
        
        // View-space hitCoord to clip-space
        projectedCoord =  vec4(hitCoord, 1.0) * cProjPS;
        // Project on screen
        //projectedCoord.xy /= projectedCoord.w;
        //projectedCoord.xy = projectedCoord.xy * 0.5 + 0.5;        
        projectedCoord.xy = GetScreenPosPreDivPS(projectedCoord);
        
        
        #ifdef HWDEPTH
            float SampledDepth = ReconstructDepth(texture2D(sDepthBuffer, projectedCoord.xy).r);
        #else
            float SampledDepth = DecodeDepth(texture2D(sDepthBuffer, projectedCoord.xy).rgb);
        #endif        
        
        // Convert ScreenSpace position to ViewSpace position
        //vec3 viewPos = GetViewPosition(projectedCoord.xy, depth);
        vec3 viewPos = vViewFarRay * -SampledDepth;
        depth = viewPos.z;
        
        // ≈сли позици€ слишком далеко от камеры
        if(depth > 0)
            continue;
        
        
        float fDepthDiff = hitCoord.z - depth;
            
        //if((dir.z - dDepth) < 1.0)
        {
            if(fDepthDiff <= 0.0)
            {   
                vec4 Result;
                Result = vec4(BinarySearch(dir, hitCoord, fDepthDiff), 1.0);
                
                //Result = vec4(0);
                
                return Result;
            }
        }
    }
 
    
    return vec4(projectedCoord.xy, depth, 0.0);
}

void PS()
{
    vec4 albedoInput = texture2D(sAlbedoBuffer, vScreenPos);
    vec4 normalInput = texture2D(sNormalBuffer, vScreenPos);
    #ifdef HWDEPTH
        float depth = ReconstructDepth(texture2D(sDepthBuffer, vScreenPos.xy).r);
    #else
        float depth = DecodeDepth(texture2D(sDepthBuffer, vScreenPos.xy).rgb);
    #endif
        
    vec3 albedo = albedoInput.rgb;
    vec3 normal = normalize(normalInput.rgb * 2.0 - 1.0);
    float specIntensity = albedoInput.a;
    float specPower = normalInput.a;
    float ssr = specPower;
    
    //if (ssr < 0.01) // 0..1
    //  discard;
  
    //vec3 viewPos = GetViewPosition(vScreenPos, depth);
    
    // Restore view position
    vec3 viewPos = vViewFarRay * -depth;
    
    // Restore world position
    vec3 worldPos = vFarRay * -depth; // wp used for generate jitt function
    
    // Transform world normal into view normal
    vec3 viewNormal = normalize(cViewTransposedPS * normal);
    //vec3 viewNormal = normalize((cViewInvPS * vec4(normal, 0)).xyz); 
      
    // Get Reflected vec 
    vec3 hitPos = viewPos;
    vec3 reflected = normalize(reflect(normalize(viewPos), viewNormal));
    
    // Jitt
    float dDepth;
    vec3 jitt = mix(vec3(0.0), vec3(hash(worldPos)), ssr / 40.0);
    
    //vec4 coords = RayMarch(reflected * max(minRayStep, -viewPos.z), hitPos, dDepth);
    
    //vec4 coords = RayMarch(reflected, hitPos, dDepth); // clean mirror
    vec4 coords = RayMarch( jitt + reflected, hitPos, dDepth); // dirty mirror with jitt
    
    // Use fresnel function to kill "lost information" on front-faced surfaces to camera  
    float fresnel = clamp(pow(1 - dot(normalize(viewPos), viewNormal), 1), 0, 1);
    
    // read reflected color from current frame
    vec3 reflectionColor = texture2D(sDiffMap, coords.xy, 0).rgb;
    // tint for ssr surfaced (used only while doing shader's debug)
    vec3 ssrTint = vec3(0.5, 0.5, 1.0);
    
    #if 1
    
    gl_FragColor = vec4(albedo + (reflectionColor * ssr * fresnel * ssrTint), specIntensity);
    
    #else // DEBUG 
    //gl_FragColor = vec4(albedo, 1);
    //gl_FragColor = vec4(viewPos, 1.0);
    //gl_FragColor = vec4(viewNormal, 1.0);
    //gl_FragColor = vec4(reflectDir, 1.0);
    //gl_FragColor = vec4(vScreenPos, 0, 1);
    //gl_FragColor = vec4(worldPos, 1);
    //gl_FragColor = vec4(normal, 1);
    //gl_FragColor = vec4(depth * 15); 
    #endif
}
#endif