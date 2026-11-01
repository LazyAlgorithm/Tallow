// Query-only fast paths. Simulation and all unsupported configurations keep Jolt's convex solver.
#include <Jolt/Jolt.h>
#include <cmath>
#include <Jolt/Physics/Collision/CollisionDispatch.h>
#include <Jolt/Physics/Collision/CollideShape.h>
#include <Jolt/Physics/Collision/CollisionCollectorImpl.h>
#include <Jolt/Physics/Collision/TransformedShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/ScaleHelpers.h>
#include <Jolt/Physics/Body/Body.h>
#include <Jolt/Physics/Body/BodyFilter.h>
#include <algorithm>
using namespace JPH;
static thread_local bool overlapContacts = false;
static CollisionDispatch::CollideShape originalSphereBox = nullptr;
static CollisionDispatch::CollideShape originalCapsuleBox = nullptr;
static CollisionDispatch::CollideShape originalBoxBox = nullptr;
extern "C" bool tn_physics_overlap_contacts(bool enabled) {
    const bool previous = overlapContacts;
    overlapContacts = enabled;
    return previous;
}
static void interiorBox(const Shape* s1, const Shape* s2, Vec3Arg scale1, Vec3Arg scale2,
    Mat44Arg t1, Mat44Arg t2, const SubShapeIDCreator& id1, const SubShapeIDCreator& id2,
    const CollideShapeSettings& settings, CollideShapeCollector& collector, const ShapeFilter& filter) {
    const bool capsule = s1->GetSubType() == EShapeSubType::Capsule;
    const auto fallback = capsule ? originalCapsuleBox : originalSphereBox;
    if (!overlapContacts || settings.mCollectFacesMode != ECollectFacesMode::NoFaces || settings.mMaxSeparationDistance != 0) {
        fallback(s1, s2, scale1, scale2, t1, t2, id1, id2, settings, collector, filter);
        return;
    }
    const auto* box = static_cast<const BoxShape*>(s2);
    const Vec3 half = box->GetHalfExtent() * scale2.Abs();
    // The round shape's centre in the box's space, and how far inside each pair of faces it is (negative: outside).
    Vec3 center = t2.InversedRotationTranslation() * t1.GetTranslation();
    Vec3 clearance = half - center.Abs();
    const float margin = ScaleHelpers::ScaleConvexRadius(box->GetConvexRadius(), scale2);
    const Vec3 sphereScale = scale1.Abs();
    // Flat-face contacts of a sphere, or of a capsule along one of the box's axes, are exact. Other features
    // retain Jolt's original convex-radius handling and supporting-face data.
    if (sphereScale.GetX() != sphereScale.GetY() ||
        sphereScale.GetX() != sphereScale.GetZ()) {
        fallback(s1, s2, scale1, scale2, t1, t2, id1, id2, settings, collector, filter);
        return;
    }

    float radius, halfHeight = 0;
    int capsuleAxis = 0;
    // A capsule whose middle is inside the box; a capsule reaching it from outside is measured from the point on its
    // segment nearest the box, as a sphere.
    bool segment = false;
    if (capsule) {
        const auto* cap = static_cast<const CapsuleShape*>(s1);
        radius = cap->GetRadius() * sphereScale.GetX();
        halfHeight = cap->GetHalfHeightOfCylinder() * sphereScale.GetX();
        const Vec3 axis = t2.Multiply3x3Transposed(t1.GetAxisY());
        if (std::abs(axis.GetY()) > std::abs(axis.GetX())) capsuleAxis = 1;
        if (std::abs(axis.GetZ()) > std::abs(axis[capsuleAxis])) capsuleAxis = 2;
        bool aligned = true;
        for (int i = 0; i < 3; ++i)
            if (i != capsuleAxis && std::abs(axis[i]) * halfHeight > 1.0e-6f) aligned = false;
        if (!aligned) {
            fallback(s1, s2, scale1, scale2, t1, t2, id1, id2, settings, collector, filter);
            return;
        }
        if (clearance.GetX() > margin && clearance.GetY() > margin && clearance.GetZ() > margin) {
            segment = true;
        } else {
            // Along its axis, the point of the segment nearest the box's span; across, the segment does not move.
            const float along = center[capsuleAxis];
            const float nearest = std::min(std::max(along, -half[capsuleAxis]), half[capsuleAxis]);
            center.SetComponent(capsuleAxis, std::min(std::max(nearest, along - halfHeight), along + halfHeight));
            clearance = half - center.Abs();
            // Inside the box but near its edges: the generic solver.
            if (clearance.GetX() >= 0 && clearance.GetY() >= 0 && clearance.GetZ() >= 0) {
                fallback(s1, s2, scale1, scale2, t1, t2, id1, id2, settings, collector, filter);
                return;
            }
        }
    } else {
        radius = static_cast<const SphereShape*>(s1)->GetRadius() * sphereScale.GetX();
    }
    if (!segment) {
        // The full box contains its convex-radius approximation: distance beyond the sphere radius proves
        // separation without a generic convex solve. Contacts near rounded edges/corners still fall back.
        const Vec3 outside = Vec3::sMax(-clearance, Vec3::sZero());
        const float rejectRadius = radius + settings.mCollisionTolerance;
        if (outside.LengthSq() > rejectRadius * rejectRadius) return;
    }
    Vec3 expandedClearance = clearance;
    if (segment) expandedClearance.SetComponent(capsuleAxis, clearance[capsuleAxis] + halfHeight);
    int axis = 0;
    if (expandedClearance.GetY() < expandedClearance.GetX()) axis = 1;
    if (expandedClearance.GetZ() < expandedClearance[axis]) axis = 2;
    if (!segment) {
        for (int i = 0; i < 3; ++i)
            if (i != axis && clearance[i] <= margin) {
                fallback(s1, s2, scale1, scale2, t1, t2, id1, id2, settings, collector, filter);
                return;
            }
    }
    Vec3 normal = Vec3::sZero();
    normal.SetComponent(axis, center[axis] < 0 ? -1.0f : 1.0f);
    const Vec3 worldNormal = t2.Multiply3x3(normal);
    const float depth = radius + expandedClearance[axis];
    const float segmentSupport = segment && axis == capsuleAxis ? halfHeight : 0;
    if (depth <= settings.mCollisionTolerance) {
        // Let the original solver resolve contacts within its collision tolerance at the tangent boundary.
        fallback(s1, s2, scale1, scale2, t1, t2, id1, id2, settings, collector, filter);
        return;
    }
    if (-depth >= collector.GetEarlyOutFraction()) return;
    CollideShapeResult result(t2 * center - worldNormal * (radius + segmentSupport),
        t2 * (center + normal * clearance[axis]), -worldNormal, depth, id1.GetID(), id2.GetID(),
        TransformedShape::sGetBodyID(collector.GetContext()));
    collector.AddHit(result);
}
static void alignedBoxes(const Shape* s1, const Shape* s2, Vec3Arg scale1, Vec3Arg scale2,
    Mat44Arg t1, Mat44Arg t2, const SubShapeIDCreator& id1, const SubShapeIDCreator& id2,
    const CollideShapeSettings& settings, CollideShapeCollector& collector, const ShapeFilter& filter) {
    const auto fallback = [&] {
        originalBoxBox(s1, s2, scale1, scale2, t1, t2, id1, id2, settings, collector, filter);
    };
    if (!overlapContacts || settings.mCollectFacesMode != ECollectFacesMode::NoFaces || settings.mMaxSeparationDistance != 0) {
        fallback(); return;
    }
    const auto* box1 = static_cast<const BoxShape*>(s1);
    const auto* box2 = static_cast<const BoxShape*>(s2);
    const Vec3 h1 = box1->GetHalfExtent() * scale1.Abs();
    const Vec3 h2 = box2->GetHalfExtent() * scale2.Abs();
    const Vec3 basis[] = {t2.Multiply3x3Transposed(t1.GetAxisX()), t2.Multiply3x3Transposed(t1.GetAxisY()), t2.Multiply3x3Transposed(t1.GetAxisZ())};
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            if (i != j && std::abs(basis[i][j]) * h1[i] > 1.0e-6f) { fallback(); return; }
    const Vec3 center = t2.InversedRotationTranslation() * t1.GetTranslation();
    const Vec3 overlap = h1 + h2 - center.Abs();
    if (overlap.GetX() < -settings.mCollisionTolerance || overlap.GetY() < -settings.mCollisionTolerance || overlap.GetZ() < -settings.mCollisionTolerance) return;
    int axis = 0;
    if (overlap.GetY() < overlap.GetX()) axis = 1;
    if (overlap.GetZ() < overlap[axis]) axis = 2;
    const float depth = overlap[axis];
    if (depth <= settings.mCollisionTolerance) { fallback(); return; }
    const Vec3 core1 = h1 - Vec3::sReplicate(ScaleHelpers::ScaleConvexRadius(box1->GetConvexRadius(), scale1));
    const Vec3 core2 = h2 - Vec3::sReplicate(ScaleHelpers::ScaleConvexRadius(box2->GetConvexRadius(), scale2));
    const Vec3 low = Vec3::sMax(center - core1, -core2);
    const Vec3 high = Vec3::sMin(center + core1, core2);
    // A shared patch inside both flat faces gives an exact face contact. Rounded edge/corner features
    // have no such patch and remain with the generic solver.
    for (int i = 0; i < 3; ++i)
        if (i != axis && high[i] - low[i] <= settings.mCollisionTolerance) { fallback(); return; }
    if (-depth >= collector.GetEarlyOutFraction()) return;
    Vec3 normal = Vec3::sZero();
    const float sign = center[axis] < 0 ? -1.0f : 1.0f;
    normal.SetComponent(axis, sign);
    Vec3 point2 = (low + high) * 0.5f;
    point2.SetComponent(axis, sign * h2[axis]);
    const Vec3 worldNormal = t2.Multiply3x3(normal);
    CollideShapeResult result(t2 * (point2 - normal * depth), t2 * point2, -worldNormal,
        depth, id1.GetID(), id2.GetID(), TransformedShape::sGetBodyID(collector.GetContext()));
    collector.AddHit(result);
}

// The squared distance from the segment a-b to a box (each axis min-max). Along the segment it is a sum of squared
// distances beyond each face, so it is quadratic between the places the segment crosses a face's plane: the least
// of each piece's lowest point is the answer.
static float segmentBoxDistanceSq(Vec3Arg a, Vec3Arg b, Vec3Arg low, Vec3Arg high) {
    const Vec3 direction = b - a;
    float breaks[8];
    int count = 0;
    breaks[count++] = 0;
    breaks[count++] = 1;
    for (int i = 0; i < 3; ++i) {
        if (std::abs(direction[i]) < 1.0e-12f) continue;
        for (const float plane : {low[i], high[i]}) {
            const float t = (plane - a[i]) / direction[i];
            if (t > 0 && t < 1) breaks[count++] = t;
        }
    }
    std::sort(breaks, breaks + count);
    float best = std::numeric_limits<float>::max();
    for (int piece = 0; piece + 1 < count; ++piece) {
        const float t0 = breaks[piece], t1 = breaks[piece + 1];
        // Which faces the piece is beyond (the same all along it), then the lowest point of its quadratic.
        const Vec3 middle = a + direction * (0.5f * (t0 + t1));
        float quadratic = 0, linear = 0;
        for (int i = 0; i < 3; ++i) {
            const float plane = middle[i] < low[i] ? low[i] : middle[i] > high[i] ? high[i] : middle[i];
            if (plane == middle[i]) continue;
            const float offset = a[i] - plane;
            quadratic += direction[i] * direction[i];
            linear += offset * direction[i];
        }
        float t = quadratic > 0 ? -linear / quadratic : t0;
        t = std::min(std::max(t, t0), t1);
        const Vec3 point = a + direction * t;
        best = std::min(best, (Vec3::sMax(low - point, Vec3::sZero()) + Vec3::sMax(point - high, Vec3::sZero())).LengthSq());
    }
    return best;
}

// Skips the bodies a sphere or capsule query cannot reach before Jolt works out their contacts. Jolt finds candidates
// by bounding box, which for a sphere also takes in the bodies off its diagonals; this measures from the sphere's centre
// (or the capsule's segment) to each body's bounds instead. It also skips the body the query ignores, before the lock.
class QueryReach final : public BodyFilter {
public:
    Vec3 start, end;
    float reach = 0;
    // round: a sphere or capsule (start to end is the capsule's segment); sphere: start and end are its centre.
    bool round = false, sphere = false;
    BodyID ignore;

    bool ShouldCollide(const BodyID& body) const override {
        return body != ignore;
    }

    bool ShouldCollideLocked(const Body& body) const override {
        if (!round) return true;
        const AABox bounds = body.GetWorldSpaceBounds();
        if (sphere) return bounds.GetSqDistanceTo(start) <= reach * reach;
        return segmentBoxDistanceSq(start, end, Vec3(bounds.mMin), Vec3(bounds.mMax)) <= reach * reach;
    }
};

// The filter for one query (each thread has its own): the shape's reach when it is a sphere or capsule.
extern "C" const void* tn_physics_query_reach(const void* shapeHandle, const float* origin, const float* rotation, uint32_t ignoreBody) {
    static thread_local QueryReach filter;
    const auto* shape = reinterpret_cast<const Shape*>(shapeHandle);
    const Vec3 center(origin[0], origin[1], origin[2]);
    filter.ignore = BodyID(ignoreBody);
    filter.round = false;
    filter.sphere = false;
    // A little past the radius, so rounding never skips a body the contact test would touch.
    const float slack = 1.0e-3f;
    if (shape->GetSubType() == EShapeSubType::Sphere) {
        filter.start = filter.end = center;
        filter.reach = static_cast<const SphereShape*>(shape)->GetRadius() + slack;
        filter.round = true;
        filter.sphere = true;
    } else if (shape->GetSubType() == EShapeSubType::Capsule) {
        const auto* capsule = static_cast<const CapsuleShape*>(shape);
        const Quat turn(rotation[0], rotation[1], rotation[2], rotation[3]);
        const Vec3 half = turn * Vec3(0, capsule->GetHalfHeightOfCylinder(), 0);
        filter.start = center - half;
        filter.end = center + half;
        filter.reach = capsule->GetRadius() + slack;
        filter.round = true;
    }
    return &filter;
}

extern "C" void tn_physics_install_query_dispatch() {
    const auto boxes = CollisionDispatch::sGetCollideShape(EShapeSubType::Box, EShapeSubType::Box);
    if (boxes != alignedBoxes) {
        originalBoxBox = boxes;
        CollisionDispatch::sRegisterCollideShape(EShapeSubType::Box, EShapeSubType::Box, alignedBoxes);
    }
    const auto sphere = CollisionDispatch::sGetCollideShape(EShapeSubType::Sphere, EShapeSubType::Box);
    if (sphere != interiorBox) {
        originalSphereBox = sphere;
        CollisionDispatch::sRegisterCollideShape(EShapeSubType::Sphere, EShapeSubType::Box, interiorBox);
    }
    const auto capsule = CollisionDispatch::sGetCollideShape(EShapeSubType::Capsule, EShapeSubType::Box);
    if (capsule != interiorBox) {
        originalCapsuleBox = capsule;
        CollisionDispatch::sRegisterCollideShape(EShapeSubType::Capsule, EShapeSubType::Box, interiorBox);
    }
}
