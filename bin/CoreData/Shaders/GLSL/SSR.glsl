#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "Transform.glsl"
#include "ScreenPos.glsl"
#line 5

varying vec2 vTexCoord;
varying vec2 vScreenPos;
varying vec3 vFarRay;
varying vec3 vViewFarRay;

#ifdef COMPILEPS
const float cSSRStep = 0.5;                    // default = 0.5, for large view distances need increase step                   
const int cSSRMaxSteps = 32;                  // default = 32
const int cSSRNumBinarySearchSteps = 16;      // default = 16  
const float cSSRReflectionFalloff = 0.01;       // 0...1.0
const float cSSRClipSSRDistance = 200;         // distance from camera to clip plane
#endif

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

vec2 GetScreenPosPreDivPS(vec4 clipPos)
{
    return vec2(
        clipPos.x / clipPos.w * cGBufferOffsetsPS.z + cGBufferOffsetsPS.x,
        clipPos.y / clipPos.w * cGBufferOffsetsPS.w + cGBufferOffsetsPS.y);
}

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
    float sampledDepth;
    vec4 projectedCoord;

    for(int i = 0; i < cSSRNumBinarySearchSteps; i++)
    {
        projectedCoord = vec4(hitCoord, 1.0) * cProjPS;
        projectedCoord.xy /= projectedCoord.w;
        projectedCoord.xy = projectedCoord.xy * 0.5 + 0.5;
        
        //projectedCoord.xy = GetScreenPosPreDivPS(projectedCoord);
 
        #ifdef HWDEPTH
            sampledDepth = ReconstructDepth(texture2D(sDepthBuffer, projectedCoord.xy).r);
        #else
            sampledDepth = DecodeDepth(texture2D(sDepthBuffer, projectedCoord.xy).rgb);
        #endif
        
        //vec3 viewPos = GetViewPosition(projectedCoord.xy, depth);
        vec3 viewPos = vViewFarRay * -sampledDepth;
        dDepth = hitCoord.z - viewPos.z;

        dir *= 0.5;
        if(dDepth > 0.0)
            hitCoord += dir;
        else
            hitCoord -= dir; 
               
    }

    projectedCoord = vec4(hitCoord, 1.0) * cProjPS;
    projectedCoord.xy /= projectedCoord.w;
    projectedCoord.xy = projectedCoord.xy * 0.5 + 0.5;
    
    //projectedCoord.xy = GetScreenPosPreDivPS(projectedCoord);
    return vec3(projectedCoord.xy, -sampledDepth);
}

vec4 RayMarch(vec3 dir, inout vec3 hitCoord, inout float dDepth)
{
    dir *= cSSRStep;
    float depth = 0;
    vec4 projectedCoord = vec4(0,0,0,0);

    for(int i = 0; i < cSSRMaxSteps; i++)
    {
        hitCoord += dir;
        
        // View-space hitCoord to clip-space
        projectedCoord =  vec4(hitCoord, 1.0) * cProjPS;
        // Project on screen
        projectedCoord.xy /= projectedCoord.w;
        projectedCoord.xy = projectedCoord.xy * 0.5 + 0.5;        
        //projectedCoord.xy = GetScreenPosPreDivPS(projectedCoord);
        
        #ifdef HWDEPTH
            float sampledDepth = ReconstructDepth(texture2D(sDepthBuffer, projectedCoord.xy).r);
        #else
            float sampledDepth = DecodeDepth(texture2D(sDepthBuffer, projectedCoord.xy).rgb);
        #endif        
        
        // Convert ScreenSpace position to ViewSpace position
        //vec3 viewPos = GetViewPosition(projectedCoord.xy, depth);
        vec3 viewPos = vViewFarRay * -sampledDepth;
        depth = viewPos.z;
        
        // ≈сли позици€ слишком далеко от камеры
        if(depth < -cSSRClipSSRDistance)
            continue;
        
        
        //float fDepthDiff = hitCoord.z - depth;
        float fDepthDiff = depth - hitCoord.z;
            
        //if((dir.z - fDepthDiff ) >= -10.0)
        {
            if(fDepthDiff >= 0.0)
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
    
    // Restore view position
    vec3 viewPos = vViewFarRay * -depth;
    
    // Transform world normal into view normal
    vec3 viewNormal = normalize(cViewTransposedPS * normal);
    //vec3 viewNormal = normalize((cViewInvPS * vec4(normal, 0)).xyz); 
      
    // Get Reflected vec 
    vec3 hitPos = viewPos;
    vec3 reflected = normalize(reflect(normalize(viewPos), viewNormal));
    
    float dDepth;
    
    #if 1
    // Use Jitt
    // Restore world position
    vec3 worldPos = vFarRay * -depth; // wp used for generate jitt function
    vec3 jitt = mix(vec3(0.0), vec3(hash(worldPos)), ssr / 50.0);
    vec4 coords = RayMarch( jitt + reflected, hitPos, dDepth); // dirty mirror with jitt
    #else
    
    vec4 coords = RayMarch(reflected, hitPos, dDepth); // clean mirror
    #endif
       
    // Use fresnel function to kill "lost information" on front-faced surfaces to camera  
    #if 0
      // fresnelSchlick version
      vec3 F0 = vec3(0.04); 
      F0 = mix(F0, albedo, ssr);
      vec3 fresnel = fresnelSchlick(max(dot(normalize(viewNormal), normalize(viewPos)), 0.0), F0);
    #else
      // simple fresnel version
      vec3 fresnel = vec3(1.0) * clamp(pow(1 - dot(normalize(viewPos), viewNormal), 1), 0, 1);
    #endif
    
    // read reflected color from current frame
    vec3 reflectionColor = texture2D(sDiffMap, coords.xy, 0).rgb;
    
    vec2 dCoords = smoothstep(0.3, 0.6, abs(vec2(0.5, 0.5) - vScreenPos.xy));
    
    float screenEdgeFactor = clamp(1.0 - (dCoords.x + dCoords.y), 0.0, 1.0);
    
    float reflectionMultiplier = pow(ssr, cSSRReflectionFalloff) * screenEdgeFactor * -reflected.z;
    
    #if 1
    
    // tint for ssr surfaced (used only while doing shader's debug)
    //vec3 ssrTint = vec3(0.5, 0.5, 1.0);
    //gl_FragColor = vec4(albedo + (reflectionColor * ssr * fresnel * ssrTint), specIntensity);
    
    gl_FragColor = vec4(albedo + (reflectionColor * clamp(reflectionMultiplier, 0.0, 0.9) * fresnel), specIntensity);
    
    #else // DEBUG
    gl_FragColor = vec4(reflectionMultiplier * fresnel,1);
    //gl_FragColor = vec4(screenEdgeFactor,screenEdgeFactor,screenEdgeFactor, 1); 
    //gl_FragColor = vec4(dCoords,0, 1);
    //gl_FragColor = vec4(fresnel, 1);
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