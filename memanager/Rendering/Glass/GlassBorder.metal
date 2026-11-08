#include <metal_stdlib>
using namespace metal;

// No desktop texture. All ray radiance below is the declared virtual studio.
// The alpha channel reserves native system glass for the real backdrop.
struct GlassBorderUniforms { float4 shape; float4 optics; float4 output; float4 transmission; float4 animation; };
constant float surfaceEpsilon = 0.012f;
constant float3 cameraRay = float3(0, 0, -1);
constant float2 WAVE_A = float2(0.018f,0.011f);
constant float2 WAVE_B = float2(-0.012f,0.023f);
constant float2 WAVE_C = float2(0.027f,-0.016f);
constant float2 WATER_A = float2(0.082f,0.026f);
constant float2 WATER_B = float2(-0.040f,0.095f);
constant float2 WATER_C = float2(0.125f,-0.071f);

static float dielectricFresnel(float cosine, float eta) {
    float c = clamp(cosine, 0.0f, 1.0f);
    float sineSquared = eta * eta * max(0.0f, 1.0f - c*c);
    if (sineSquared >= 1.0f) return 1.0f;
    float t = sqrt(max(0.0f, 1.0f - sineSquared));
    float rs = (eta*c-t) / max(eta*c+t, 0.00001f);
    float rp = (c-eta*t) / max(c+eta*t, 0.00001f);
    return 0.5f * (rs*rs + rp*rp);
}

static float softbox(float3 ray, float3 direction, float2 halfSize) {
    float3 forward = normalize(direction);
    float3 right = normalize(cross(float3(0,1,0), forward));
    float3 up = cross(forward, right);
    float facing = dot(ray, forward);
    if (facing <= 0.0f) return 0.0f;
    float2 edge = abs(float2(dot(ray,right),dot(ray,up)) / facing) / halfSize;
    return 1.0f - smoothstep(0.88f, 1.0f, max(edge.x,edge.y));
}

static float3 studio(float3 ray) {
    float key = softbox(ray, float3(-0.55f,-0.5f,0.66f), float2(0.95f,0.48f));
    float fill = softbox(ray, float3(0.65f,0.3f,0.7f), float2(0.5f,1.05f));
    // Rear lights are seen through both glass interfaces. Neutral light edges
    // acquire color only because each RGB wavelength takes a different ray.
    float rear = softbox(ray, float3(-0.45f,-0.16f,-1), float2(0.24f,1.1f));
    float rearFill = softbox(ray, float3(0.6f,0.35f,-1), float2(0.5f,0.22f));
    return clamp(float3(0.035f,0.045f,0.055f)
        + float3(0.96f,0.94f,0.89f)*key + float3(0.61f,0.74f,0.85f)*fill
        + float3(0.96f)*rear + float3(0.72f)*rearFill, 0.0f, 1.0f);
}

// A deterministic cone filter approximates surface roughness. It does not
// perturb the intersected geometry or claim stochastic microfacet transport.
static float3 filteredStudio(float3 ray, float roughness) {
    if (roughness <= 0.0f) return studio(ray);
    float3 axis = abs(ray.z) > 0.9f ? float3(0,1,0) : float3(0,0,1);
    float3 tangent = normalize(cross(axis,ray)) * roughness * 2.0f;
    float3 bitangent = cross(ray,tangent);
    return studio(ray)*0.4f + 0.15f*(studio(normalize(ray+tangent))
        + studio(normalize(ray-tangent)) + studio(normalize(ray+bitangent))
        + studio(normalize(ray-bitangent)));
}

struct OpticalPath { float3 exitRay; float transmission; bool exited; };

struct GlassScene {
    GlassBorderUniforms u;
    float radius() const { return max(0.0001f, u.shape.w*0.5f); }
    float contourAmplitude() const {
        float r = radius();
        float2 halfSize = u.shape.xy*0.5f-r;
        float corner = clamp(u.shape.z-r,0.0f,min(halfSize.x,halfSize.y));
        return min(r*0.24f*clamp(u.animation.y,0.0f,1.0f),corner*0.5f);
    }
    float height() const {
        float highestIOR = max(1.0001f, u.optics.x+u.transmission.x);
        // Bounds for the sums of weighted wavevector lengths and squared lengths.
        // Use the requested amplitude here so the model and shader share one cap.
        float r = radius(), amplitude = r*0.24f*clamp(u.animation.y,0.0f,1.0f);
        float d1 = 1.0f+amplitude*0.0239f, d2 = amplitude*0.000585f;
        float water = clamp(u.animation.w,0.0f,1.0f), q = 1.0f-0.04f*water;
        float q1 = 0.18f*water*0.1019f, q2 = 0.18f*water*0.01082f;
        float curvature = q*q2+q*q/(r*r)*(d1*d1+r*d2)+4.0f*q/r*q1*d1;
        float maximum = sqrt(0.70f/((1.0f-1.0f/highestIOR)*curvature));
        // Preserve thickness as full ellipse thickness in the existing API.
        return min(max(0.001f,u.optics.y*0.5f),maximum);
    }
    float epsilon() const { return min(surfaceEpsilon,min(radius(),height())*0.002f); }
    // Water uses a finer surface-height field, independent of contour gooeyness.
    // Sum-of-sines geometry and analytic derivatives follow GPU Gems chapter 1.
    float minimumHeight() const { return height()*(1.0f-0.40f*u.animation.w); }
    float heightGradientBound() const {
        return height()*0.18f*u.animation.w*(0.50f*length(WATER_A)
            +0.32f*length(WATER_B)+0.18f*length(WATER_C));
    }
    float3 heightField(float2 point) const {
        float h = height(), water = u.animation.w;
        if (water <= 0.0f) return float3(h,0,0);
        float2 p = point-u.shape.xy*0.5f;
        float3 phase = float3(dot(p,WATER_A),dot(p,WATER_B),dot(p,WATER_C))
            +u.animation.x*float3(-1.8f,2.3f,-3.1f);
        float wave = dot(float3(0.50f,0.32f,0.18f),sin(phase));
        float2 gradient = 0.50f*WATER_A*cos(phase.x)+0.32f*WATER_B*cos(phase.y)
            +0.18f*WATER_C*cos(phase.z);
        return float3(h*(1.0f-0.22f*water+0.18f*water*wave),h*0.18f*water*gradient);
    }
    // Spatial wave and its exact gradient deform every optical intersection.
    float3 liquidWave(float2 point) const {
        float amplitude = contourAmplitude();
        if (amplitude <= 0.0f) return float3(0);
        float2 local = point - float2(0) - u.shape.xy * 0.5f;
        float3 phase = float3(dot(local, WAVE_A), dot(local, WAVE_B), dot(local, WAVE_C))
            + u.animation.x * float3(0.92f, -0.63f, 1.31f);
        float wave = dot(float3(0.58f, 0.28f, 0.14f), sin(phase));
        float2 gradient = 0.58f * WAVE_A * cos(phase.x) + 0.28f * WAVE_B * cos(phase.y)
            + 0.14f * WAVE_C * cos(phase.z);
        return amplitude * float3(wave, gradient);
    }

    float fieldGradientBound() const {
        return 1.0f + contourAmplitude()
            * (0.58f * length(WAVE_A) + 0.28f * length(WAVE_B) + 0.14f * length(WAVE_C));
    }
    // The original contour also bounds the native paint gutter.
    float3 baseCenterline(float2 point) const {
        float2 local = point-u.shape.xy*0.5f;
        float2 halfSize = u.shape.xy*0.5f-radius();
        float corner = clamp(u.shape.z-radius(), 0.0f, min(halfSize.x,halfSize.y));
        float2 q = abs(local)-halfSize+corner;
        float2 outside = max(q,0.0f);
        float magnitude = length(outside);
        float2 gradient = magnitude > 0.00001f ? outside/magnitude
            : (q.x > q.y ? float2(1,0) : float2(0,1));
        gradient *= select(float2(1),float2(-1),local < 0);
        return float3(magnitude+min(max(q.x,q.y),0.0f)-corner,gradient);
    }
    float3 centerline(float2 point) const {
        return baseCenterline(point)-liquidWave(point);
    }
    float4 perimeterLight(float phase) const {
        float inset = radius();
        float2 low = float2(0) + inset, high = float2(0) + u.shape.xy - inset;
        float corner = clamp(u.shape.z - inset, 0.0f, min(high.x - low.x, high.y - low.y) * 0.5f);
        float horizontal = high.x - low.x - 2.0f * corner;
        float vertical = high.y - low.y - 2.0f * corner;
        float arc = corner * 1.570796327f;
        float distance = fract(phase) * (2.0f * horizontal + 2.0f * vertical + 4.0f * arc);
        float2 position, normal;
        if (distance < horizontal) { position = float2(low.x + corner + distance, low.y); normal = float2(0,-1); }
        else if ((distance -= horizontal) < arc) { float a = -1.570796327f + distance / max(corner, 0.001f); normal = float2(cos(a),sin(a)); position = float2(high.x-corner,low.y+corner)+normal*corner; }
        else if ((distance -= arc) < vertical) { position = float2(high.x,low.y+corner+distance); normal=float2(1,0); }
        else if ((distance -= vertical) < arc) { float a=distance/max(corner,0.001f); normal=float2(cos(a),sin(a)); position=float2(high.x-corner,high.y-corner)+normal*corner; }
        else if ((distance -= arc) < horizontal) { position=float2(high.x-corner-distance,high.y); normal=float2(0,1); }
        else if ((distance -= horizontal) < arc) { float a=1.570796327f+distance/max(corner,0.001f); normal=float2(cos(a),sin(a)); position=float2(low.x+corner,high.y-corner)+normal*corner; }
        else if ((distance -= arc) < vertical) { position=float2(low.x,high.y-corner-distance); normal=float2(-1,0); }
        else { distance -= vertical; float a=3.141592654f+distance/max(corner,0.001f); normal=float2(cos(a),sin(a)); position=float2(low.x+corner,low.y+corner)+normal*corner; }
        float3 field = centerline(position);
        position -= normal * field.x / max(dot(field.yz, normal), 0.5f);
        return float4(position, normalize(centerline(position).yz));
    }

    float3 movingReflection(float3 entry, float3 normal) const {
        if (u.animation.z <= 0.0f) return float3(0.0f);
        float4 lamp = perimeterLight(u.animation.x * 0.10f);
        float elevation = height() + 28.0f;
        float3 toLight = float3(lamp.xy + lamp.zw * (radius() + 12.0f), elevation) - entry;
        float3 light = normalize(toLight);
        float3 halfway = normalize(light - cameraRay);
        float exponent = mix(24.0f, 10.0f, clamp(u.optics.z * 10.0f, 0.0f, 1.0f));
        float lobe = pow(max(dot(normal, halfway), 0.0f), exponent) * max(dot(normal, light), 0.0f);
        float attenuation = elevation * elevation / max(dot(toLight, toLight), 1.0f);
        float cosine = max(dot(-cameraRay, halfway), 0.0f);
        float3 fresnel = float3(dielectricFresnel(cosine, 1.0f / max(1.0f, u.optics.x-u.transmission.x)),
            dielectricFresnel(cosine, 1.0f / max(1.0f, u.optics.x)),
            dielectricFresnel(cosine, 1.0f / max(1.0f, u.optics.x+u.transmission.x)));
        return float3(1.0f, 0.985f, 0.96f) * fresnel * lobe * attenuation * 3.8f * u.animation.z;
    }
    float distance(float3 point) const {
        float curved = (length(float2(centerline(point.xy).x/radius(),point.z/heightField(point.xy).x))-1)
            * min(radius(),minimumHeight())/(fieldGradientBound()+heightGradientBound());
        return max(curved,-point.z);
    }
    float3 curvedNormal(float3 point) const {
        float3 d = centerline(point.xy);
        float3 h = heightField(point.xy);
        float zOverH = point.z/h.x;
        // Gradient of (d/r)^2 + (z/h(x,y))^2. The height derivative is essential.
        return normalize(float3(d.yz*d.x/(radius()*radius())-zOverH*zOverH*h.yz/h.x,
            point.z/(h.x*h.x)));
    }
    float3 normal(float3 point) const {
        return point.z < epsilon()*1.5f ? float3(0,0,-1) : curvedNormal(point);
    }
    bool nextInterface(float3 start, float3 direction, thread float3 &hit) const {
        if (u.animation.y <= 0 && u.animation.w <= 0 && direction.z < -0.0001f) {
            float planeT = -start.z/direction.z;
            float3 planeHit = start+direction*planeT;
            if (planeT > 0.0f && abs(centerline(planeHit.xy).x) <= radius()) {
                hit = float3(planeHit.xy,0); return true;
            }
        }
        float minHeight = minimumHeight(), floorScale = min(radius(),minHeight);
        float speed = max(length(float2(length(direction.xy)*fieldGradientBound()/radius(),
            (abs(direction.z)+heightGradientBound()*length(direction.xy))/minHeight)),
            abs(direction.z)/floorScale);
        float t = 0, previous = 0;
        for (int step = 0; step < 48; ++step) {
            float3 point = start+direction*t;
            float3 d = centerline(point.xy);
            float3 h = heightField(point.xy);
            float2 section = float2(d.x/radius(),point.z/h.x);
            float sectionLength = length(section);
            float curvedDistance = sectionLength-1;
            float planeDistance = -point.z/floorScale;
            float value = max(curvedDistance,planeDistance);
            if (value > 0 && t > 0) {
                float low = previous, high = t;
                for (int refinement = 0; refinement < 6; ++refinement) {
                    float middle = (low+high)*0.5f;
                    if (distance(start+direction*middle) < 0) low = middle;
                    else high = middle;
                }
                hit = start+direction*((low+high)*0.5f); return true;
            }
            if (t > epsilon()*4 && abs(value)/speed < epsilon()) {
                hit = point; return true;
            }
            previous = t;
            float derivative = planeDistance > curvedDistance ? -direction.z/floorScale
                : dot(section,float2(dot(d.yz,direction.xy)/radius(),
                    (direction.z-section.y*dot(h.yz,direction.xy))/h.x)) / max(sectionLength,0.00001f);
            float advance = -value/(derivative > 0 ? max(derivative,speed*0.4f) : speed);
            t += max(advance*0.9f,epsilon()*1.5f);
        }
        return false;
    }
    OpticalPath trace(float3 entry, float3 entryNormal, float ior) const {
        OpticalPath result = {reflect(cameraRay,entryNormal),0,false};
        float3 direction = refract(cameraRay,entryNormal,1.0f/ior);
        float weight = 1.0f-dielectricFresnel(dot(-cameraRay,entryNormal),1.0f/ior);
        float3 origin = entry+direction*(epsilon()*4);
        for (int bounce = 0; bounce < 3; ++bounce) {
            float3 hit;
            if (!nextInterface(origin,direction,hit)) return result;
            float3 outward = normal(hit);
            float3 transmitted = refract(direction,-outward,ior);
            if (dot(transmitted,transmitted) > 0.0001f) {
                result.exitRay = normalize(transmitted);
                result.transmission = weight*(1-dielectricFresnel(max(dot(direction,outward),0.0f),ior));
                result.exited = true; return result;
            }
            direction = reflect(direction,outward);
            origin = hit+direction*(epsilon()*4);
        }
        return result;
    }
};

kernel void glassBorder(texture2d<float, access::write> destination [[texture(0)]],
                        constant GlassBorderUniforms &u [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
    if (id.x >= destination.get_width() || id.y >= destination.get_height()) return;
    float2 pixelSize = u.shape.xy/float2(destination.get_width(),destination.get_height());
    float2 point = (float2(id)+0.5f)*pixelSize;
    GlassScene scene = {u};
    float pixelWidth = max(pixelSize.x,pixelSize.y);
    float original = clamp((scene.radius()-abs(scene.baseCenterline(point).x))/pixelWidth+0.5f,0.0f,1.0f);
    // Most panel pixels are not glass rim. Reject them before wave trigonometry.
    if (original <= 0 || u.optics.x+u.transmission.x <= 1.00001f || u.optics.y <= 0.0001f || u.optics.w <= 0) {
        destination.write(float4(0),id); return;
    }
    float3 field = scene.centerline(point);
    float distance = field.x;
    float deformed = clamp((scene.radius()-abs(distance))/(pixelWidth*max(length(field.yz),0.0001f))+0.5f,0.0f,1.0f);
    float coverage = min(original,deformed);
    if (coverage <= 0) {
        destination.write(float4(0),id); return;
    }
    float section = clamp(distance/scene.radius(),-0.9995f,0.9995f);
    float3 entry = float3(point,scene.heightField(point).x*sqrt(1-section*section));
    float3 normal = scene.curvedNormal(entry);
    float3 reflected = filteredStudio(reflect(cameraRay,normal),u.optics.z);
    float3 transmitted = float3(0);
    float reflectionWeight = dielectricFresnel(dot(-cameraRay,normal),1.0f/u.optics.x);
    float transmissionEnergy = 0;
    if (u.transmission.y > 0) {
        OpticalPath green = scene.trace(entry,normal,u.optics.x);
        transmitted = filteredStudio(green.exitRay,u.optics.z);
        transmissionEnergy = green.transmission;
    }
    if (u.transmission.x > 0.00001f) {
        float redIOR = max(1.0f,u.optics.x-u.transmission.x);
        if (u.transmission.y > 0) {
            OpticalPath red = scene.trace(entry,normal,redIOR);
            OpticalPath blue = scene.trace(entry,normal,u.optics.x+u.transmission.x);
            transmitted.r = filteredStudio(red.exitRay,u.optics.z).r;
            transmitted.b = filteredStudio(blue.exitRay,u.optics.z).b;
            transmissionEnergy = (transmissionEnergy+red.transmission+blue.transmission)/3.0f;
        }
        float cosine = dot(-cameraRay,normal);
        reflectionWeight = (reflectionWeight+dielectricFresnel(cosine,1.0f/redIOR)
            +dielectricFresnel(cosine,1.0f/(u.optics.x+u.transmission.x)))/3.0f;
    }
    // Source over cannot carry wavelength dependent backdrop coefficients.
    // Average RGB interface energy for scalar alpha; retain RGB ray directions.
    // Only the computed front reflection and successful exit are composited.
    // Untraced internal energy stays with the native backdrop approximation.
    float transmissionWeight = u.transmission.y*transmissionEnergy;
    float weight = reflectionWeight+transmissionWeight;
    float alpha = coverage*u.optics.w*weight;
    float3 color = weight > 0 ? (reflectionWeight*reflected+transmissionWeight*transmitted+scene.movingReflection(entry,normal))/weight : float3(0);
    if (u.output.x > 0.5f) {
        color = select(1.055f*pow(max(color,0.0f),float3(1.0f/2.4f))-0.055f,
                       color*12.92f,color <= 0.0031308f);
    }
    destination.write(float4(clamp(color,0.0f,1.0f)*alpha,alpha),id);
}
