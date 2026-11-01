// Soft bodies (cloth, jelly, rubber) on Jolt's soft body simulation, behind a small C ABI for Engine/src/Physics/SoftBody.bf.
// Jolt steps them on the job threads with the rest of the world and collides them with every other body. What Jolt
// leaves to the caller lives here: building the shared settings from a mesh, moving pinned vertices with an object,
// wind on the faces, and reading the vertices back for drawing and networking. The joltc handles are Jolt's own
// objects (joltc casts them), so this file reaches past joltc where it has no call for something.
#include <Jolt/Jolt.h>
#include <Jolt/Physics/Body/Body.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Body/BodyLock.h>
#include <Jolt/Physics/Body/BodyLockInterface.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyLockMulti.h>
#include <Jolt/Physics/Collision/ContactListener.h>
#include <Jolt/Physics/Collision/GroupFilter.h>
#include <Jolt/Physics/Collision/Shape/MeshShape.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>
#include <Jolt/Physics/Constraints/PulleyConstraint.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/SoftBody/SoftBodyContactListener.h>
#include <Jolt/Physics/SoftBody/SoftBodyCreationSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodyManifold.h>
#include <Jolt/Physics/SoftBody/SoftBodyMotionProperties.h>
#include <Jolt/Physics/SoftBody/SoftBodySharedSettings.h>
#include <Jolt/Core/TempAllocator.h>
#include "joltc.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#if defined(_WIN32)
#define TN_API extern "C" __declspec(dllexport)
#else
#define TN_API extern "C" __attribute__((visibility("default")))
#endif

namespace
{

/// SoftBody.bf's settings, in the same order.
struct Config
{
	float mass;           // the whole body's mass (kg), shared by the vertices that are not pinned
	float stretch;        // compliance of the edges (0 does not stretch; higher stretches more)
	float shear;          // compliance of the edges across faces
	float bend;           // compliance of bending; below 0 bends freely
	float pressure;       // pushes a closed mesh outward (jelly, balls, tyres); 0 for cloth
	float damping;        // how fast the vertices lose speed
	float friction;
	float restitution;
	float gravityFactor;
	float vertexRadius;   // how far from the surface collisions keep other things
	float dentDepth;      // shell: how far a vertex can be pushed from its place on the object in one impact
	float dentYield;      // shell: how far it springs back from; pushed further, the rest stays dented
	float dentSpeed;      // shell: how fast (m/s) a vertex must be pushed in for it to dent
	float stepTime;       // the physics step (s): with iterations, how stiff a constraint can be and still settle
	int32_t iterations;   // solver passes per step
	int32_t doubleSided;  // faces collide from both sides (cloth)
	int32_t longRange;    // keep free vertices within reach of the pins (stops cloth stretching under its weight)
	int32_t dihedral;     // bend by the angle between faces (jelly) rather than by distance (cloth)
	int32_t shell;        // every vertex is held near its place on the object (skinned to it), which dents
	int32_t impacts;      // shell: held exactly in place, dented by its object's collider's hits instead of its own
	uint32_t layer;
	uint64_t userData;
};

const JPH::BodyLockInterface& Locks(JPH_PhysicsSystem* world)
{
	return *reinterpret_cast<const JPH::BodyLockInterface*>(JPH_PhysicsSystem_GetBodyLockInterface(world));
}

JPH::BodyInterface& Bodies(JPH_PhysicsSystem* world)
{
	return *reinterpret_cast<JPH::BodyInterface*>(JPH_PhysicsSystem_GetBodyInterface(world));
}

JPH::SoftBodyMotionProperties* Soft(JPH::Body& body)
{
	return body.IsSoftBody() ? static_cast<JPH::SoftBodyMotionProperties*>(body.GetMotionProperties()) : nullptr;
}

/// joltc's JPH_PhysicsSystem (third_party/joltc/src/joltc.cpp), to reach the Jolt system it wraps.
struct JoltcSystem
{
	void* broadPhaseLayerInterface;
	void* objectLayerPairFilter;
	void* objectVsBroadPhaseLayerFilter;
	JPH::PhysicsSystem* physicsSystem;
};

JPH::Mat44 Matrix(const float* m)
{
	return JPH::Mat44(JPH::Vec4(m[0], m[1], m[2], m[3]), JPH::Vec4(m[4], m[5], m[6], m[7]), JPH::Vec4(m[8], m[9], m[10], m[11]),
		JPH::Vec4(m[12], m[13], m[14], m[15]));
}

/// A shell's places on its object as made (bind positions), to repair it and to measure its dents by.
struct Shell
{
	std::vector<JPH::Float3> original;
	// Each vertex's outward direction as made (bind space): only a push inward dents.
	std::vector<JPH::Float3> outward;
	// The vertices that touched something since the last step: only they dent (the rest were only shaken).
	std::vector<uint8_t> touched;
	JPH::Mat44 bindToObject;
	float dentYield = 0;
	float dentSpeed = 0;
	float dentDepth = 0;
	bool skinned = false;
	// Dented by its object's hits (Impacts) rather than by being pushed in itself; the object's body, once known.
	bool fromImpacts = false;
	uint32_t owner = 0xFFFFFFFFu;
	// Counts up each time it dents (or its dents are set), for tn_soft_dent_revision.
	uint32_t revision = 0;
	// Hits on the object since the last step, at Dent Speed or faster: where (up to four points on its surface, in
	// the world), which way into it, how fast, and the two bodies' masses as they meet (reduced) and its own.
	struct Hit
	{
		JPH::Vec3 points[4];
		int count = 0;
		JPH::Vec3 into;
		float speed = 0;
		float reducedMass = 0;
		float ownMass = 0;
	};
	std::vector<Hit> hits;
	// Where the object was when last skinned to (the end of that step), to leave a shell asleep while it stays.
	JPH::Mat44 lastObject = JPH::Mat44::sZero();
};

/// Soft bodies only meet rigid bodies in the physics engine, so a closed soft body near another soft body gets a
/// proxy: a kinematic body shaped like its surface, rebuilt every step, which other soft bodies (and nothing else)
/// collide with. Group: the soft body's id; sub group 0 a closed soft body, 1 a proxy, 2 an open one (cloth).
class SoftGroups final : public JPH::GroupFilter
{
public:
	static constexpr JPH::CollisionGroup::SubGroupID Closed = 0, Proxy = 1, Open = 2;

	bool CanCollide(const JPH::CollisionGroup& a, const JPH::CollisionGroup& b) const override
	{
		const bool aOurs = a.GetGroupFilter() == this, bOurs = b.GetGroupFilter() == this;
		const bool aProxy = aOurs && a.GetSubGroupID() == Proxy, bProxy = bOurs && b.GetSubGroupID() == Proxy;
		if (!aProxy && !bProxy)
			return true;
		// A proxy meets soft bodies only, never its own, and not another proxy.
		if (!aOurs || !bOurs || (aProxy && bProxy) || a.GetGroupID() == b.GetGroupID())
			return false;
		// Cloth meets every proxy. Of two closed bodies, only one meets the other's proxy: both at once would
		// each push against a surface that cannot give, and fight.
		const JPH::CollisionGroup& soft = aProxy ? b : a;
		const JPH::CollisionGroup& proxy = aProxy ? a : b;
		return soft.GetSubGroupID() == Open || soft.GetGroupID() > proxy.GetGroupID();
	}
};

/// Made on first use: Jolt allocates through functions it is given at start-up, after static initialisation.
SoftGroups* Groups()
{
	static JPH::Ref<SoftGroups> groups = new SoftGroups();
	return groups.GetPtr();
}

/// Every proxy's body id, for rays, shape queries and characters to pass through (tn_soft_is_proxy).
std::mutex gProxyMutex;
std::unordered_set<uint32_t> gProxies;

/// Remembers which bodies each soft body's vertices touched, until asked (soft bodies update on the job threads),
/// and keeps each soft body off the bodies it should ignore (a shell's own rigidbody).
class Touches final : public JPH::SoftBodyContactListener, public JPH::ContactListener
{
public:
	JPH::SoftBodyValidateResult OnSoftBodyContactValidate(const JPH::Body& soft, const JPH::Body& other, JPH::SoftBodyContactSettings&) override
	{
		std::lock_guard<std::mutex> guard(mutex);
		// A shell dented by its object's hits only follows the object: the object's collider meets everything.
		auto shell = shells.find(soft.GetID().GetIndexAndSequenceNumber());
		if (shell != shells.end() && shell->second.fromImpacts)
			return JPH::SoftBodyValidateResult::RejectContact;
		auto found = ignored.find(soft.GetID().GetIndexAndSequenceNumber());
		if (found != ignored.end() && std::find(found->second.begin(), found->second.end(), other.GetID().GetIndexAndSequenceNumber()) != found->second.end())
			return JPH::SoftBodyValidateResult::RejectContact;
		return JPH::SoftBodyValidateResult::AcceptContact;
	}

	void OnSoftBodyContactAdded(const JPH::Body& soft, const JPH::SoftBodyManifold& manifold) override
	{
		std::lock_guard<std::mutex> guard(mutex);
		const uint32_t id = soft.GetID().GetIndexAndSequenceNumber();
		auto& touched = bodies[id];
		auto shell = shells.find(id);
		const auto& vertices = manifold.GetVertices();
		if (shell != shells.end())
			shell->second.touched.resize(vertices.size());
		for (size_t i = 0; i < vertices.size(); i++)
		{
			if (!manifold.HasContact(vertices[i]))
				continue;
			touched.insert(manifold.GetContactBodyID(vertices[i]).GetIndexAndSequenceNumber());
			if (shell != shells.end())
				shell->second.touched[i] = 1;
		}
		// A rope keeps which way each of its points was pushed off what it touched (zero where it touched nothing),
		// as the step clears it: tn_rope_wraps reads it.
		auto rope = ropes.find(id);
		if (rope != ropes.end())
		{
			rope->second.assign(vertices.size(), JPH::Vec3::sZero());
			for (size_t i = 0; i < vertices.size(); i++)
			{
				if (manifold.HasContact(vertices[i]))
					rope->second[i] = vertices[i].mCollisionPlane.GetNormal();
			}
		}
	}

	/// Rigid bodies meeting: a hit on a shell's object, by something static or dynamic (not a character or a moving
	/// platform), at the shell's Dent Speed or faster, is kept for its next tn_soft_skin.
	void OnContactAdded(const JPH::Body& one, const JPH::Body& two, const JPH::ContactManifold& manifold, JPH::ContactSettings&) override
	{
		std::lock_guard<std::mutex> guard(mutex);
		for (int side = 0; side < 2; side++)
		{
			const JPH::Body& own = side == 0 ? one : two;
			const JPH::Body& other = side == 0 ? two : one;
			auto owner = shellOwners.find(own.GetID().GetIndexAndSequenceNumber());
			if (owner == shellOwners.end() || other.IsSensor() || other.IsKinematic() || other.IsSoftBody())
				continue;
			auto shell = shells.find(owner->second);
			if (shell == shells.end())
				continue;
			// The manifold's normal points from the first body to the second.
			const JPH::Vec3 into = side == 0 ? -manifold.mWorldSpaceNormal : manifold.mWorldSpaceNormal;
			Shell::Hit hit;
			hit.count = std::min((int)manifold.mRelativeContactPointsOn1.size(), 4);
			if (hit.count == 0)
				continue;
			for (int i = 0; i < hit.count; i++)
				hit.points[i] = JPH::Vec3(side == 0 ? manifold.GetWorldSpaceContactPointOn1(i) : manifold.GetWorldSpaceContactPointOn2(i));
			const JPH::RVec3 at(hit.points[0]);
			hit.speed = (other.GetPointVelocity(at) - own.GetPointVelocity(at)).Dot(into);
			if (hit.speed < shell->second.dentSpeed)
				continue;
			const float ownInverse = own.IsDynamic() ? own.GetMotionPropertiesUnchecked()->GetInverseMass() : 0.0f;
			const float otherInverse = other.IsDynamic() ? other.GetMotionPropertiesUnchecked()->GetInverseMass() : 0.0f;
			if (ownInverse + otherInverse <= 0)
				continue;
			hit.reducedMass = 1.0f / (ownInverse + otherInverse);
			hit.ownMass = ownInverse > 0 ? 1.0f / ownInverse : hit.reducedMass;
			hit.into = into;
			shell->second.hits.push_back(hit);
		}
	}

	std::mutex mutex;
	// Shells dented by their object's hits, by their object's body.
	std::unordered_map<uint32_t, uint32_t> shellOwners;
	std::unordered_map<uint32_t, std::unordered_set<uint32_t>> bodies;
	std::unordered_map<uint32_t, std::vector<uint32_t>> ignored;
	std::unordered_map<uint32_t, Shell> shells;
	// Each rope's points' contact normals in the last step (relative to the body), for tn_rope_wraps.
	std::unordered_map<uint32_t, std::vector<JPH::Vec3>> ropes;
	// Each soft body's proxy, while it has one.
	std::unordered_map<uint32_t, uint32_t> proxies;
};

std::unordered_map<JPH::PhysicsSystem*, Touches*> gTouches;

Touches& TouchesOf(JPH_PhysicsSystem* world)
{
	auto* system = reinterpret_cast<JoltcSystem*>(world)->physicsSystem;
	auto& touches = gTouches[system];
	if (touches == nullptr)
	{
		touches = new Touches();
		system->SetSoftBodyContactListener(touches);
		system->SetContactListener(touches);
	}
	return *touches;
}

} // namespace

/// Makes a soft body from a welded mesh: positions (x, y, z per vertex, in the world, relative to `center`),
/// triangles (three vertex indices each), pinned (per vertex, 1 held in place by MovePinned, 0 free) and stiffness
/// (per vertex, multiplies how hard it resists stretching; null for 1). Returns the body's id, or 0xFFFFFFFF.
/// A shell (config->shell) also takes `objectMatrix`, its object's local-to-world matrix as it is made (16 floats,
/// column by column), and holds every vertex within dentDepth of where it sits on the object (tn_soft_skin).
TN_API uint32_t tn_soft_create(JPH_PhysicsSystem* world, const Config* config, const float* positions, uint32_t vertexCount, const uint32_t* triangles,
	uint32_t triangleCount, const float* pinned, const float* stiffness, const float* center, const float* objectMatrix)
{
	const bool shell = config && config->shell != 0 && objectMatrix;
	if (!world || !config || !positions || vertexCount < 3 || !triangles || triangleCount == 0)
		return 0xFFFFFFFFu;
	uint32_t free = 0;
	for (uint32_t i = 0; i < vertexCount; i++)
		free += (pinned && pinned[i] >= 0.5f) ? 0 : 1;

	// Each free vertex weighs its share of the surface (a third of each face round it), so many small faces round
	// one point (a sphere's poles) are not heavy against the large ones elsewhere.
	std::vector<float> area(vertexCount, 0.0f);
	float freeArea = 0;
	for (uint32_t t = 0; t < triangleCount; t++)
	{
		const uint32_t a = triangles[t * 3], b = triangles[t * 3 + 1], c = triangles[t * 3 + 2];
		if (a >= vertexCount || b >= vertexCount || c >= vertexCount)
			continue;
		const JPH::Vec3 pa(positions[a * 3], positions[a * 3 + 1], positions[a * 3 + 2]);
		const JPH::Vec3 pb(positions[b * 3], positions[b * 3 + 1], positions[b * 3 + 2]);
		const JPH::Vec3 pc(positions[c * 3], positions[c * 3 + 1], positions[c * 3 + 2]);
		const float third = (pb - pa).Cross(pc - pa).Length() / 6.0f;
		for (uint32_t corner : { a, b, c })
			area[corner] += third;
	}
	for (uint32_t i = 0; i < vertexCount; i++)
		freeArea += (pinned && pinned[i] >= 0.5f) ? 0.0f : area[i];

	JPH::Ref<JPH::SoftBodySharedSettings> shared = new JPH::SoftBodySharedSettings();
	shared->mVertices.reserve(vertexCount);
	for (uint32_t i = 0; i < vertexCount; i++)
	{
		JPH::SoftBodySharedSettings::Vertex vertex;
		vertex.mPosition = JPH::Float3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
		const float share = (freeArea > 1.0e-9f && area[i] > 1.0e-9f) ? area[i] / freeArea : 1.0f / float(std::max(free, 1u));
		vertex.mInvMass = (pinned && pinned[i] >= 0.5f) ? 0.0f : 1.0f / std::max(config->mass * share, 1.0e-6f);
		shared->mVertices.push_back(vertex);
	}
	for (uint32_t t = 0; t < triangleCount; t++)
	{
		const uint32_t a = triangles[t * 3], b = triangles[t * 3 + 1], c = triangles[t * 3 + 2];
		if (a >= vertexCount || b >= vertexCount || c >= vertexCount || a == b || b == c || a == c)
			continue;
		shared->AddFace(JPH::SoftBodySharedSettings::Face(a, b, c));
	}
	if (shared->mFaces.empty())
		return 0xFFFFFFFFu;

	// Per vertex: softer where the stiffness map is low. A pinned vertex's edges keep the default.
	// Each constraint is also kept no stiffer than one solver pass can settle for vertices as light as its own: Jolt's
	// compliance is absolute, so a light or finely meshed body (a 1 kg cloth of 1,000 vertices weighs a gram a
	// vertex) is otherwise effectively rigid everywhere, and rigid edges and shear fight each other as soon as it
	// folds or is squeezed (draped over a ball, crumpled by waves), throwing vertices about until it blows apart.
	// The floor is the compliance at which a pass corrects about two thirds of an edge's error. A shell is held by
	// its object instead.
	const float pass = std::max(config->stepTime, 1.0e-4f) / (float)std::clamp(config->iterations, 1, 64);
	const float averageMass = std::max(config->mass, 1.0e-6f) / float(std::max(free, 1u));
	std::vector<JPH::SoftBodySharedSettings::VertexAttributes> attributes(vertexCount);
	const auto longRange = (config->longRange != 0 && free < vertexCount) ? JPH::SoftBodySharedSettings::ELRAType::EuclideanDistance : JPH::SoftBodySharedSettings::ELRAType::None;
	for (uint32_t i = 0; i < vertexCount; i++)
	{
		const float scale = stiffness ? std::max(stiffness[i], 0.02f) : 1.0f;
		const float vertexMass = shared->mVertices[i].mInvMass > 0 ? 1.0f / shared->mVertices[i].mInvMass : averageMass;
		const float floor = shell ? 0.0f : pass * pass * 2.0f / vertexMass;
		attributes[i] = JPH::SoftBodySharedSettings::VertexAttributes(std::max(std::max(config->stretch, 0.0f) / scale, floor),
			std::max(std::max(config->shear, 0.0f) / scale, floor), config->bend < 0 ? FLT_MAX : std::max(config->bend / scale, floor), longRange);
	}
	if (shell)
	{
		// One joint, the object: bind positions (relative to center, in the world as made) to the object's space.
		const JPH::Mat44 bindToObject = Matrix(objectMatrix).Inversed() * JPH::Mat44::sTranslation(JPH::Vec3(center[0], center[1], center[2]));
		shared->mInvBindMatrices.push_back(JPH::SoftBodySharedSettings::InvBind(0, bindToObject));
		for (uint32_t i = 0; i < vertexCount; i++)
		{
			const bool held = pinned && pinned[i] >= 0.5f;
			// Dented by its object's hits, it follows the object exactly; otherwise it can be pushed in up to dentDepth.
			const float give = (held || config->impacts != 0) ? 0.0f : std::max(config->dentDepth, 0.001f);
			JPH::SoftBodySharedSettings::Skinned skinned(i, give, FLT_MAX, 0.0f);
			skinned.mWeights[0] = JPH::SoftBodySharedSettings::SkinWeight(0, 1.0f);
			shared->mSkinnedConstraints.push_back(skinned);
		}
	}
	const auto bendType = config->bend < 0 ? JPH::SoftBodySharedSettings::EBendType::None
		: (config->dihedral != 0 ? JPH::SoftBodySharedSettings::EBendType::Dihedral : JPH::SoftBodySharedSettings::EBendType::Distance);
	shared->CreateConstraints(attributes.data(), (JPH::uint)attributes.size(), bendType);
	shared->Optimize();

	JPH::SoftBodyCreationSettings settings(shared, JPH::RVec3(center[0], center[1], center[2]), JPH::Quat::sIdentity(), (JPH::ObjectLayer)config->layer);
	settings.mUserData = config->userData;
	settings.mNumIterations = (JPH::uint32)std::clamp(config->iterations, 1, 64);
	settings.mLinearDamping = std::max(config->damping, 0.0f);
	settings.mFriction = std::max(config->friction, 0.0f);
	settings.mRestitution = std::clamp(config->restitution, 0.0f, 1.0f);
	settings.mGravityFactor = config->gravityFactor;
	settings.mPressure = std::max(config->pressure, 0.0f);
	settings.mVertexRadius = std::max(config->vertexRadius, 0.0f);
	settings.mFacesDoubleSided = config->doubleSided != 0;
	settings.mUpdatePosition = true;
	settings.mMakeRotationIdentity = true;
	settings.mAllowSleeping = true;
	auto& touches = TouchesOf(world);
	const JPH::BodyID id = Bodies(world).CreateAndAddSoftBody(settings, JPH::EActivation::Activate);
	if (id.IsInvalid())
		return 0xFFFFFFFFu;
	{
		JPH::BodyLockWrite lock(Locks(world), id);
		if (lock.Succeeded())
			lock.GetBody().SetCollisionGroup(JPH::CollisionGroup(Groups(), id.GetIndexAndSequenceNumber(),
				(config->pressure > 0 || config->shell != 0 || config->doubleSided == 0) ? SoftGroups::Closed : SoftGroups::Open));
	}
	if (shell)
	{
		std::lock_guard<std::mutex> guard(touches.mutex);
		auto& kept = touches.shells[id.GetIndexAndSequenceNumber()];
		kept.bindToObject = shared->mInvBindMatrices[0].mInvBind;
		kept.dentYield = std::max(config->dentYield, 0.0f);
		kept.dentSpeed = std::max(config->dentSpeed, 0.0f);
		kept.dentDepth = std::max(config->dentDepth, 0.001f);
		kept.fromImpacts = config->impacts != 0;
		for (const auto& vertex : shared->mVertices)
			kept.original.push_back(vertex.mPosition);
		std::vector<JPH::Vec3> outward(shared->mVertices.size(), JPH::Vec3::sZero());
		for (const auto& face : shared->mFaces)
		{
			const JPH::Vec3 a(shared->mVertices[face.mVertex[0]].mPosition), b(shared->mVertices[face.mVertex[1]].mPosition),
				c(shared->mVertices[face.mVertex[2]].mPosition);
			const JPH::Vec3 normal = (b - a).Cross(c - a);
			for (uint32_t corner : face.mVertex)
				outward[corner] += normal;
		}
		for (const auto& normal : outward)
		{
			kept.outward.emplace_back();
			normal.NormalizedOr(JPH::Vec3::sZero()).StoreFloat3(&kept.outward.back());
		}
	}
	return id.GetIndexAndSequenceNumber();
}

TN_API uint32_t tn_soft_vertex_count(JPH_PhysicsSystem* world, uint32_t bodyId)
{
	JPH::BodyLockRead lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded())
		return 0;
	auto* soft = Soft(const_cast<JPH::Body&>(lock.GetBody()));
	return soft ? (uint32_t)soft->GetVertices().size() : 0;
}

/// The vertices where they are now, in the world (x, y, z each), and how fast they move if velocities is not null.
TN_API uint32_t tn_soft_read(JPH_PhysicsSystem* world, uint32_t bodyId, float* positions, float* velocities, uint32_t capacity)
{
	JPH::BodyLockRead lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded())
		return 0;
	const JPH::Body& body = lock.GetBody();
	auto* soft = Soft(const_cast<JPH::Body&>(body));
	if (!soft)
		return 0;
	const JPH::RMat44 transform = body.GetCenterOfMassTransform();
	const auto& vertices = soft->GetVertices();
	const uint32_t count = std::min<uint32_t>((uint32_t)vertices.size(), capacity);
	for (uint32_t i = 0; i < count; i++)
	{
		const JPH::RVec3 p = transform * vertices[i].mPosition;
		positions[i * 3] = float(p.GetX());
		positions[i * 3 + 1] = float(p.GetY());
		positions[i * 3 + 2] = float(p.GetZ());
		if (velocities)
		{
			const JPH::Vec3 v = transform.Multiply3x3(vertices[i].mVelocity);
			velocities[i * 3] = v.GetX();
			velocities[i * 3 + 1] = v.GetY();
			velocities[i * 3 + 2] = v.GetZ();
		}
	}
	return count;
}

/// Moves pinned vertices (indices) to where they should be by the end of the next step (targets in the world): each
/// gets the speed that takes it there in `step` seconds, so what it touches on the way is pushed rather than jumped
/// through. Wakes the body when anything moves.
TN_API void tn_soft_move_pinned(JPH_PhysicsSystem* world, uint32_t bodyId, const uint32_t* indices, const float* targets, uint32_t count, float step)
{
	if (count == 0 || step <= 0)
		return;
	bool moved = false;
	{
		JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
		if (!lock.Succeeded())
			return;
		JPH::Body& body = lock.GetBody();
		auto* soft = Soft(body);
		if (!soft)
			return;
		const JPH::RMat44 inverse = body.GetInverseCenterOfMassTransform();
		auto& vertices = soft->GetVertices();
		for (uint32_t i = 0; i < count; i++)
		{
			if (indices[i] >= vertices.size())
				continue;
			auto& vertex = vertices[indices[i]];
			const JPH::Vec3 target = JPH::Vec3(inverse * JPH::RVec3(targets[i * 3], targets[i * 3 + 1], targets[i * 3 + 2]));
			vertex.mVelocity = (target - vertex.mPosition) / step;
			moved |= vertex.mVelocity.LengthSq() > 1.0e-8f;
		}
	}
	if (moved)
		Bodies(world).ActivateBody(JPH::BodyID(bodyId));
}

/// Puts every vertex at a place in the world, still (after a teleport, or a correction from the server).
TN_API void tn_soft_set_positions(JPH_PhysicsSystem* world, uint32_t bodyId, const float* positions, const float* velocities, uint32_t count)
{
	{
		JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
		if (!lock.Succeeded())
			return;
		JPH::Body& body = lock.GetBody();
		auto* soft = Soft(body);
		if (!soft)
			return;
		const JPH::RMat44 transform = body.GetCenterOfMassTransform();
		const JPH::RMat44 inverse = body.GetInverseCenterOfMassTransform();
		auto& vertices = soft->GetVertices();
		const uint32_t n = std::min<uint32_t>(count, (uint32_t)vertices.size());
		for (uint32_t i = 0; i < n; i++)
		{
			vertices[i].mPosition = JPH::Vec3(inverse * JPH::RVec3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]));
			vertices[i].mPreviousPosition = vertices[i].mPosition;
			vertices[i].mVelocity = velocities ? transform.Multiply3x3Transposed(JPH::Vec3(velocities[i * 3], velocities[i * 3 + 1], velocities[i * 3 + 2])) : JPH::Vec3::sZero();
		}
	}
	Bodies(world).ActivateBody(JPH::BodyID(bodyId));
}

namespace
{

/// The air at a point, with `turbulence` (0 steady, 1 rough) added: gusts that travel downwind across a surface
/// (about 3 m apart, passing 1 to 3 times a second as the wind gets up) and a sideways flutter, so a flag ripples and
/// flaps instead of standing out flat.
JPH::Vec3 TurbulentAir(JPH::Vec3Arg air, JPH::Vec3Arg at, float turbulence, float time)
{
	const float speed = air.Length();
	if (turbulence <= 0 || speed < 1.0e-4f)
		return air;
	const JPH::Vec3 along = air / speed;
	JPH::Vec3 side = along.Cross(JPH::Vec3::sAxisY());
	side = side.LengthSq() > 1.0e-6f ? side.Normalized() : JPH::Vec3::sAxisX();
	const JPH::Vec3 up = side.Cross(along);
	const float wave = along.Dot(at) * 2.0f - time * std::min(speed * 1.6f, 19.0f);
	const float gust = 1.0f + turbulence * (0.45f * std::sin(wave) + 0.2f * std::sin(wave * 2.3f + 1.7f + 1.5f * up.Dot(at)));
	const float flutter = turbulence * 0.6f * std::sin(wave * 1.3f + 0.8f * up.Dot(at) + 1.3f * side.Dot(at));
	return air * gust + side * (speed * flutter);
}

} // namespace

/// Air moving at `wind` (m/s, in the world) pushes on each face by how squarely it meets it: half the air's density
/// times drag times area times the speed into the face squared, shared by the face's free vertices, over `step`
/// seconds. Air along a face drags it downwind a little too (what stretches a flag out), and `turbulence` (0-1) makes
/// the air differ from face to face (TurbulentAir) at `time`.
TN_API void tn_soft_wind(JPH_PhysicsSystem* world, uint32_t bodyId, const float* wind, float drag, float turbulence, float time, float step)
{
	if (drag <= 0 || step <= 0)
		return;
	const JPH::Vec3 air(wind[0], wind[1], wind[2]);
	bool pushed = false;
	{
		JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
		if (!lock.Succeeded())
			return;
		JPH::Body& body = lock.GetBody();
		auto* soft = Soft(body);
		if (!soft)
			return;
		const JPH::Mat44 toLocal = body.GetInverseCenterOfMassTransform().ToMat44();
		const JPH::Mat44 toWorld = body.GetCenterOfMassTransform().ToMat44();
		auto& vertices = soft->GetVertices();
		const float density = 1.2f;
		// Skin friction: how much air sliding along a face drags it, against straight into it.
		const float along = 0.1f;
		for (const auto& face : soft->GetSettings()->mFaces)
		{
			auto& a = vertices[face.mVertex[0]];
			auto& b = vertices[face.mVertex[1]];
			auto& c = vertices[face.mVertex[2]];
			JPH::Vec3 normal = (b.mPosition - a.mPosition).Cross(c.mPosition - a.mPosition);
			const float twiceArea = normal.Length();
			if (twiceArea < 1.0e-9f)
				continue;
			normal /= twiceArea;
			const JPH::Vec3 middle = (a.mPosition + b.mPosition + c.mPosition) / 3.0f;
			const JPH::Vec3 localAir = toLocal.Multiply3x3(TurbulentAir(air, toWorld * middle, turbulence, time));
			const JPH::Vec3 relative = localAir - (a.mVelocity + b.mVelocity + c.mVelocity) / 3.0f;
			const float into = normal.Dot(relative);
			const JPH::Vec3 sliding = relative - normal * into;
			const float share = 0.5f * density * drag * 0.5f * twiceArea * step / 3.0f;
			const JPH::Vec3 impulse = (normal * (into * std::abs(into)) + sliding * (along * sliding.Length())) * share;
			for (auto* vertex : { &a, &b, &c })
				vertex->mVelocity += impulse * vertex->mInvMass;
			pushed |= relative.LengthSq() > 1.0e-4f;
		}
	}
	if (pushed)
		Bodies(world).ActivateBody(JPH::BodyID(bodyId));
}

/// Wind on a rope (tn_rope_create): each point is pushed by the air crossing it, as a cylinder `radius` thick, with
/// the same drag, turbulence and time as tn_soft_wind.
TN_API void tn_rope_wind(JPH_PhysicsSystem* world, uint32_t bodyId, const float* wind, float radius, float drag, float turbulence, float time, float step)
{
	if (drag <= 0 || step <= 0)
		return;
	const JPH::Vec3 air(wind[0], wind[1], wind[2]);
	bool pushed = false;
	{
		JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
		if (!lock.Succeeded())
			return;
		JPH::Body& body = lock.GetBody();
		auto* soft = Soft(body);
		if (!soft)
			return;
		const JPH::Mat44 toLocal = body.GetInverseCenterOfMassTransform().ToMat44();
		const JPH::Mat44 toWorld = body.GetCenterOfMassTransform().ToMat44();
		auto& vertices = soft->GetVertices();
		const size_t count = vertices.size();
		const float density = 1.2f, cylinder = 1.2f;
		for (size_t i = 0; i < count && count > 1; i++)
		{
			auto& vertex = vertices[i];
			if (vertex.mInvMass <= 0)
				continue;
			const JPH::Vec3 before = vertices[i > 0 ? i - 1 : i].mPosition, after = vertices[i + 1 < count ? i + 1 : i].mPosition;
			JPH::Vec3 tangent = after - before;
			// The rope this point stands for: half of each length beside it.
			const float span = tangent.Length() * ((i == 0 || i + 1 == count) ? 1.0f : 0.5f);
			if (span < 1.0e-6f)
				continue;
			tangent = tangent.Normalized();
			const JPH::Vec3 localAir = toLocal.Multiply3x3(TurbulentAir(air, toWorld * vertex.mPosition, turbulence, time));
			JPH::Vec3 across = localAir - vertex.mVelocity;
			across -= tangent * tangent.Dot(across);
			const JPH::Vec3 impulse = across * (0.5f * density * cylinder * drag * 2.0f * radius * span * across.Length() * step);
			vertex.mVelocity += impulse * vertex.mInvMass;
			pushed |= across.LengthSq() > 1.0e-4f;
		}
	}
	if (pushed)
		Bodies(world).ActivateBody(JPH::BodyID(bodyId));
}

/// The bodies a soft body's vertices have touched since this was last asked (up to capacity of them); returns how many.
TN_API uint32_t tn_soft_touching(JPH_PhysicsSystem* world, uint32_t bodyId, uint32_t* output, uint32_t capacity)
{
	auto& touches = TouchesOf(world);
	std::lock_guard<std::mutex> guard(touches.mutex);
	auto found = touches.bodies.find(bodyId);
	if (found == touches.bodies.end())
		return 0;
	uint32_t count = 0;
	for (uint32_t id : found->second)
	{
		if (count < capacity)
			output[count] = id;
		count++;
	}
	touches.bodies.erase(found);
	return std::min(count, capacity);
}

/// Forgets a world's contact listener (when the world is destroyed).
TN_API void tn_soft_world_destroyed(JPH_PhysicsSystem* world)
{
	auto* system = reinterpret_cast<JoltcSystem*>(world)->physicsSystem;
	auto found = gTouches.find(system);
	if (found == gTouches.end())
		return;
	system->SetSoftBodyContactListener(nullptr);
	system->SetContactListener(nullptr);
	{
		std::lock_guard<std::mutex> guard(gProxyMutex);
		for (const auto& [owner, proxy] : found->second->proxies)
			gProxies.erase(proxy);
	}
	delete found->second;
	gTouches.erase(found);
}

/// Moves every vertex by an offset (in the world), keeping how they move: a teleport, or easing towards where the
/// server says the body is.
TN_API void tn_soft_shift(JPH_PhysicsSystem* world, uint32_t bodyId, const float* offset)
{
	{
		JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
		if (!lock.Succeeded())
			return;
		JPH::Body& body = lock.GetBody();
		auto* soft = Soft(body);
		if (!soft)
			return;
		const JPH::Vec3 local = body.GetInverseCenterOfMassTransform().Multiply3x3(JPH::Vec3(offset[0], offset[1], offset[2]));
		for (auto& vertex : soft->GetVertices())
		{
			vertex.mPosition += local;
			vertex.mPreviousPosition += local;
		}
	}
	Bodies(world).ActivateBody(JPH::BodyID(bodyId));
}

/// Keeps a soft body's vertices from colliding with a body (a shell's own rigidbody, what a rope is tied to);
/// 0xFFFFFFFF forgets them all.
TN_API void tn_soft_ignore(JPH_PhysicsSystem* world, uint32_t bodyId, uint32_t ignoredBody)
{
	auto& touches = TouchesOf(world);
	std::lock_guard<std::mutex> guard(touches.mutex);
	if (ignoredBody == 0xFFFFFFFFu)
		touches.ignored.erase(bodyId);
	else
	{
		touches.ignored[bodyId].push_back(ignoredBody);
		// A shell ignores only its object's body: the one whose hits dent it (the latest, when the body is made again,
		// as when its collider follows its dents).
		auto shell = touches.shells.find(bodyId);
		if (shell != touches.shells.end())
		{
			touches.shellOwners.erase(shell->second.owner);
			shell->second.owner = ignoredBody;
			if (shell->second.fromImpacts)
				touches.shellOwners[ignoredBody] = bodyId;
		}
	}
}

/// Forgets what was kept about a soft body (when it is removed).
void RemoveProxy(JPH_PhysicsSystem* world, uint32_t proxy);

TN_API void tn_soft_forget(JPH_PhysicsSystem* world, uint32_t bodyId)
{
	auto& touches = TouchesOf(world);
	std::lock_guard<std::mutex> guard(touches.mutex);
	auto proxy = touches.proxies.find(bodyId);
	if (proxy != touches.proxies.end())
	{
		RemoveProxy(world, proxy->second);
		touches.proxies.erase(proxy);
	}
	touches.ignored.erase(bodyId);
	auto shell = touches.shells.find(bodyId);
	if (shell != touches.shells.end())
	{
		touches.shellOwners.erase(shell->second.owner);
		touches.shells.erase(shell);
	}
	touches.ropes.erase(bodyId);
	touches.bodies.erase(bodyId);
}

namespace
{

/// Where a shell's vertex sits on its object now, in the body's space: object (bind to object, then to the world)
/// then into the body.
JPH::Mat44 BindToBody(const JPH::Body& body, const Shell& shell, const float* objectMatrix)
{
	const JPH::Mat44 worldToBody = body.GetInverseCenterOfMassTransform().ToMat44();
	return worldToBody * Matrix(objectMatrix) * shell.bindToObject;
}

/// Edges' rest lengths from the bind positions (after dents moved them), so the edges keep a dent rather than
/// pulling it back out.
void RestLengthsFromBind(JPH::SoftBodySharedSettings& settings)
{
	for (auto& edge : settings.mEdgeConstraints)
	{
		const JPH::Vec3 a(settings.mVertices[edge.mVertex[0]].mPosition), b(settings.mVertices[edge.mVertex[1]].mPosition);
		edge.mRestLength = (b - a).Length();
	}
}

} // namespace

/// Before a step, for a shell: dents (vertices pushed further than dentYield from their place keep the rest of the
/// way as their new place), springs the rest back towards their places, and holds every vertex within dentDepth of
/// where its object will put it by the end of the step. objectMatrix: the object's local-to-world matrix now;
/// objectNext: where it will be after the step (it moves with its rigidbody during the step).
namespace
{

/// Dents a shell (Impacts) from the hits on its object: around each, the surface facing what hit it is pressed in
/// along the hit, deeper the faster it was past Dent Speed (full Dent Depth at four times it) and the heavier what
/// hit it (full with a tenth of the object's mass or more, or anything static), fading out over a reach that grows
/// with the speed. Returns whether anything moved. worldToBind: world positions to the shell's bind space.
bool DentFromHits(Shell& shell, JPH::SoftBodySharedSettings& settings, const JPH::Mat44& worldToBind)
{
	bool dented = false;
	for (const auto& hit : shell.hits)
	{
		const float hard = std::clamp((hit.speed - shell.dentSpeed) / std::max(shell.dentSpeed * 3.0f, 0.5f), 0.0f, 1.0f);
		const float heavy = std::clamp(hit.reducedMass / std::max(hit.ownMass * 0.1f, 0.001f), 0.0f, 1.0f);
		const float depth = shell.dentDepth * hard * heavy;
		if (depth < 0.002f)
			continue;
		const float reach = std::clamp(0.25f + 0.04f * hit.speed, 0.25f, 1.0f);
		const JPH::Vec3 into = worldToBind.Multiply3x3(hit.into).NormalizedOr(JPH::Vec3::sAxisZ());
		// The patch the hit covered, flat across the hit: its corners' extent along two directions in that plane.
		const JPH::Vec3 across = into.GetNormalizedPerpendicular();
		const JPH::Vec3 down = into.Cross(across);
		JPH::Vec3 first = worldToBind * hit.points[0];
		float low[2] = { FLT_MAX, FLT_MAX }, high[2] = { -FLT_MAX, -FLT_MAX };
		for (int i = 0; i < hit.count; i++)
		{
			const JPH::Vec3 point = worldToBind * hit.points[i];
			const float flat[2] = { point.Dot(across), point.Dot(down) };
			for (int k = 0; k < 2; k++)
			{
				low[k] = std::min(low[k], flat[k]);
				high[k] = std::max(high[k], flat[k]);
			}
		}
		const float surface = first.Dot(into);
		for (uint32_t i = 0; i < settings.mVertices.size(); i++)
		{
			auto& bind = settings.mVertices[i].mPosition;
			JPH::Vec3 place(bind);
			// Only the side facing what hit it: not the far side, nor a panel turned away.
			if (i < shell.outward.size() && JPH::Vec3(shell.outward[i]).Dot(into) > 0.3f)
				continue;
			const float behind = place.Dot(into) - surface;
			const float flat[2] = { place.Dot(across), place.Dot(down) };
			float off = std::max(behind, 0.0f) * std::max(behind, 0.0f);
			for (int k = 0; k < 2; k++)
			{
				const float outside = std::max({ low[k] - flat[k], flat[k] - high[k], 0.0f });
				off += outside * outside;
			}
			float fade = 1.0f - std::sqrt(off) / reach;
			if (fade <= 0)
				continue;
			fade = fade * fade * (3.0f - 2.0f * fade);
			place += into * (depth * fade);
			// Never more than three impacts deep from how it was made.
			const JPH::Vec3 original(shell.original[i]);
			const JPH::Vec3 moved = place - original;
			const float limit = shell.dentDepth * 3.0f;
			if (moved.LengthSq() > limit * limit)
				place = original + moved.Normalized() * limit;
			place.StoreFloat3(&bind);
			dented = true;
		}
	}
	return dented;
}

} // namespace

TN_API void tn_soft_skin(JPH_PhysicsSystem* world, uint32_t bodyId, const float* objectMatrix, const float* objectNext, float step)
{
	static JPH::TempAllocatorMalloc temp;
	auto& touches = TouchesOf(world);
	std::lock_guard<std::mutex> guard(touches.mutex);
	auto found = touches.shells.find(bodyId);
	if (found == touches.shells.end())
		return;
	Shell& shell = found->second;
	{
		JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
		if (!lock.Succeeded())
			return;
		JPH::Body& body = lock.GetBody();
		auto* soft = Soft(body);
		if (!soft)
			return;
		// Asleep, with its object where it was: nothing to do, and no reason to wake it.
		const JPH::Mat44 next = Matrix(objectNext);
		if (shell.skinned && !body.IsActive() && next == shell.lastObject && shell.hits.empty())
			return;
		shell.lastObject = next;
		auto& settings = const_cast<JPH::SoftBodySharedSettings&>(*soft->GetSettings());
		const JPH::Mat44 bindToBody = BindToBody(body, shell, objectMatrix);
		const JPH::Mat44 bindToBodyNext = BindToBody(body, shell, objectNext);
		const JPH::Mat44 bodyToBind = bindToBody.Inversed();
		auto& vertices = soft->GetVertices();
		bool dented = false;
		if (shell.fromImpacts && !shell.hits.empty())
			dented = DentFromHits(shell, settings, bodyToBind * body.GetInverseCenterOfMassTransform().ToMat44());
		shell.hits.clear();
		if (shell.skinned)
		{
			for (uint32_t i = 0; i < vertices.size(); i++)
			{
				auto& vertex = vertices[i];
				if (vertex.mInvMass == 0)
					continue;
				auto& bind = settings.mVertices[i].mPosition;
				const JPH::Vec3 place = bindToBody * JPH::Vec3(bind);
				// Only a push into the surface by something it touched dents it; dragging along it (friction) and
				// shaking (the object stopping short) spring back.
				const JPH::Vec3 out = bindToBody.Multiply3x3(JPH::Vec3(shell.outward[i])).NormalizedOr(JPH::Vec3::sZero());
				const JPH::Vec3 away = vertex.mPosition - place;
				const float depth = -away.Dot(out);
				const bool hit = i < shell.touched.size() && shell.touched[i] != 0;
				// How fast it is being pushed in, against the object carrying it: a crash, not something resting on it
				// or leaning on it.
				const JPH::Vec3 carriedNow = step > 0 ? (bindToBodyNext * JPH::Vec3(bind) - place) / step : JPH::Vec3::sZero();
				const float inward = -(vertex.mVelocity - carriedNow).Dot(out);
				if (hit && depth > shell.dentYield && inward >= shell.dentSpeed)
				{
					// Pushed in past what springs back: the rest of the way it was pushed is a dent.
					JPH::Vec3(bodyToBind * (place + away * (1.0f - shell.dentYield / depth))).StoreFloat3(&bind);
					dented = true;
				}
				// What is left springs back over a few steps, and wobbling on the object dies away; the object's
				// own motion carries the vertex.
				if (step > 0)
				{
					const JPH::Vec3 now = bindToBody * JPH::Vec3(bind);
					const JPH::Vec3 carried = (bindToBodyNext * JPH::Vec3(bind) - now) / step;
					const JPH::Vec3 back = now - vertex.mPosition;
					vertex.mVelocity = carried + (vertex.mVelocity - carried) * 0.75f + back * (0.25f / step);
				}
			}
		}
		std::fill(shell.touched.begin(), shell.touched.end(), 0);
		if (dented)
		{
			RestLengthsFromBind(settings);
			shell.revision++;
		}
		const JPH::Mat44 joint = body.GetInverseCenterOfMassTransform().ToMat44() * Matrix(objectNext);
		soft->SkinVertices(body.GetCenterOfMassTransform(), &joint, 1, !shell.skinned, temp);
		shell.skinned = true;
		if (body.IsActive() && !dented)
			return;
	}
	Bodies(world).ActivateBody(JPH::BodyID(bodyId));
}

/// A shell's dents: per vertex, how far it has been moved on its object (in the object's space, x, y, z each).
TN_API uint32_t tn_soft_dents(JPH_PhysicsSystem* world, uint32_t bodyId, float* output, uint32_t capacity)
{
	auto& touches = TouchesOf(world);
	std::lock_guard<std::mutex> guard(touches.mutex);
	auto found = touches.shells.find(bodyId);
	if (found == touches.shells.end())
		return 0;
	JPH::BodyLockRead lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded())
		return 0;
	auto* soft = Soft(const_cast<JPH::Body&>(lock.GetBody()));
	if (!soft)
		return 0;
	const auto& settings = *soft->GetSettings();
	const Shell& shell = found->second;
	const uint32_t count = std::min<uint32_t>((uint32_t)settings.mVertices.size(), capacity);
	for (uint32_t i = 0; i < count; i++)
	{
		const JPH::Vec3 moved = shell.bindToObject.Multiply3x3(JPH::Vec3(settings.mVertices[i].mPosition) - JPH::Vec3(shell.original[i]));
		moved.StoreFloat3(reinterpret_cast<JPH::Float3*>(output + i * 3));
	}
	return count;
}

/// How many times a shell has dented (or had its dents set): its collider follows when this changes.
TN_API uint32_t tn_soft_dent_revision(JPH_PhysicsSystem* world, uint32_t bodyId)
{
	auto& touches = TouchesOf(world);
	std::lock_guard<std::mutex> guard(touches.mutex);
	auto found = touches.shells.find(bodyId);
	return found == touches.shells.end() ? 0 : found->second.revision;
}

/// Sets a shell's dents (as tn_soft_dents gives them; null repairs it), moving its vertices to match.
TN_API void tn_soft_set_dents(JPH_PhysicsSystem* world, uint32_t bodyId, const float* dents, uint32_t count, const float* objectMatrix)
{
	auto& touches = TouchesOf(world);
	std::lock_guard<std::mutex> guard(touches.mutex);
	auto found = touches.shells.find(bodyId);
	if (found == touches.shells.end())
		return;
	{
		JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
		if (!lock.Succeeded())
			return;
		JPH::Body& body = lock.GetBody();
		auto* soft = Soft(body);
		if (!soft)
			return;
		Shell& shell = found->second;
		auto& settings = const_cast<JPH::SoftBodySharedSettings&>(*soft->GetSettings());
		const JPH::Mat44 objectToBind = shell.bindToObject.Inversed();
		const JPH::Mat44 bindToBody = BindToBody(body, shell, objectMatrix);
		auto& vertices = soft->GetVertices();
		for (uint32_t i = 0; i < settings.mVertices.size(); i++)
		{
			JPH::Vec3 bind(shell.original[i]);
			if (dents && i < count)
				bind += objectToBind.Multiply3x3(JPH::Vec3(dents[i * 3], dents[i * 3 + 1], dents[i * 3 + 2]));
			bind.StoreFloat3(&settings.mVertices[i].mPosition);
			vertices[i].mPosition = bindToBody * bind;
			vertices[i].mPreviousPosition = vertices[i].mPosition;
			vertices[i].mVelocity = JPH::Vec3::sZero();
		}
		RestLengthsFromBind(settings);
		shell.skinned = false;
		shell.revision++;
	}
	Bodies(world).ActivateBody(JPH::BodyID(bodyId));
}

/// Changes how hard a closed soft body's air pushes out (Jolt's n R T: pressure times rest volume).
TN_API void tn_soft_set_pressure(JPH_PhysicsSystem* world, uint32_t bodyId, float pressure)
{
	JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded())
		return;
	if (auto* soft = Soft(lock.GetBody()))
		soft->SetPressure(std::max(pressure, 0.0f));
}

/// Slows the vertices' movement against the body as a whole (its wobbling, and springing back from a squash) by
/// `rate` a second, leaving how the whole body moves alone.
TN_API void tn_soft_damp_wobble(JPH_PhysicsSystem* world, uint32_t bodyId, float rate, float step)
{
	if (rate <= 0 || step <= 0)
		return;
	JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded() || !lock.GetBody().IsActive())
		return;
	auto* soft = Soft(lock.GetBody());
	if (!soft)
		return;
	auto& vertices = soft->GetVertices();
	JPH::Vec3 momentum = JPH::Vec3::sZero();
	float mass = 0;
	for (const auto& vertex : vertices)
	{
		if (vertex.mInvMass <= 0)
			continue;
		momentum += vertex.mVelocity / vertex.mInvMass;
		mass += 1.0f / vertex.mInvMass;
	}
	if (mass <= 0)
		return;
	const JPH::Vec3 whole = momentum / mass;
	const float keep = std::max(0.0f, 1.0f - rate * step);
	for (auto& vertex : vertices)
	{
		if (vertex.mInvMass > 0)
			vertex.mVelocity = whole + (vertex.mVelocity - whole) * keep;
	}
}

/// A soft body's (or a rope's) box in the world, as Jolt last moved it. False when there is no such body.
TN_API bool tn_soft_bounds(JPH_PhysicsSystem* world, uint32_t bodyId, float* min, float* max)
{
	JPH::BodyLockRead lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded() || !lock.GetBody().IsSoftBody())
		return false;
	const JPH::AABox box = lock.GetBody().GetWorldSpaceBounds();
	box.mMin.StoreFloat3((JPH::Float3*)min);
	box.mMax.StoreFloat3((JPH::Float3*)max);
	return true;
}

/// Floats a soft body (or a rope) in water for one step. The water's surface over the body is given as a grid of
/// samples, nx by nz from (minX, minZ) every cellX by cellZ metres, each its height and the water's velocity (four
/// floats). Every vertex under the surface is pushed up by gravity times buoyancy, fading in over `band` metres round
/// the surface, and eased towards the water's velocity at `drag` times a second. Vertices below `bottom` and held ones
/// are left alone. A sleeping body is woken first when `wake` (the water moves), and otherwise only counted. Returns how many
/// vertices were under.
TN_API uint32_t tn_soft_float(JPH_PhysicsSystem* world, uint32_t bodyId, const float* samples, uint32_t nx, uint32_t nz, float minX, float minZ, float cellX,
	float cellZ, float bottom, float band, float buoyancy, float drag, float gravity, float step, bool wake)
{
	if (nx < 1 || nz < 1 || step <= 0 || band <= 0)
		return 0;
	if (wake)
		Bodies(world).ActivateBody(JPH::BodyID(bodyId));
	JPH::BodyLockWrite lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded())
		return 0;
	JPH::Body& body = lock.GetBody();
	auto* soft = Soft(body);
	if (!soft)
		return 0;
	// Asleep (settled in still water): only counted, so it stays asleep.
	const bool awake = body.IsActive();
	const JPH::RMat44 toWorld = body.GetCenterOfMassTransform();
	const JPH::Mat44 toLocal = body.GetInverseCenterOfMassTransform();
	const float lift = gravity * buoyancy * step;
	uint32_t under = 0;
	for (auto& vertex : soft->GetVertices())
	{
		if (vertex.mInvMass <= 0)
			continue;
		const JPH::Vec3 p = JPH::Vec3(toWorld * vertex.mPosition);
		if (p.GetY() < bottom)
			continue;
		// The surface here, between the four samples round it.
		const float gx = std::clamp((p.GetX() - minX) / cellX, 0.0f, (float)(nx - 1));
		const float gz = std::clamp((p.GetZ() - minZ) / cellZ, 0.0f, (float)(nz - 1));
		const uint32_t x0 = std::min((uint32_t)gx, nx - 1), z0 = std::min((uint32_t)gz, nz - 1);
		const uint32_t x1 = std::min(x0 + 1, nx - 1), z1 = std::min(z0 + 1, nz - 1);
		const float fx = gx - x0, fz = gz - z0;
		float water[4];
		for (int c = 0; c < 4; c++)
		{
			const float a = samples[(z0 * nx + x0) * 4 + c] * (1 - fx) + samples[(z0 * nx + x1) * 4 + c] * fx;
			const float b = samples[(z1 * nx + x0) * 4 + c] * (1 - fx) + samples[(z1 * nx + x1) * 4 + c] * fx;
			water[c] = a * (1 - fz) + b * fz;
		}
		const float wet = std::clamp((water[0] - p.GetY()) / band + 0.5f, 0.0f, 1.0f);
		if (wet <= 0)
			continue;
		under++;
		if (!awake)
			continue;
		const JPH::Vec3 flow = toLocal.Multiply3x3(JPH::Vec3(water[1], water[2], water[3]));
		vertex.mVelocity = flow + (vertex.mVelocity - flow) * std::exp(-std::max(drag, 0.0f) * wet * step);
		vertex.mVelocity += toLocal.Multiply3x3(JPH::Vec3(0, lift * wet, 0));
	}
	return under;
}

extern "C" void tn_physics_set_debris(uint32_t bodyId, bool debris);

void RemoveProxy(JPH_PhysicsSystem* world, uint32_t proxy)
{
	Bodies(world).RemoveBody(JPH::BodyID(proxy));
	Bodies(world).DestroyBody(JPH::BodyID(proxy));
	tn_physics_set_debris(proxy, false);
	std::lock_guard<std::mutex> guard(gProxyMutex);
	gProxies.erase(proxy);
}

/// Whether a body is a soft body's proxy (which only other soft bodies touch).
TN_API bool tn_soft_is_proxy(uint32_t bodyId)
{
	std::lock_guard<std::mutex> guard(gProxyMutex);
	return gProxies.count(bodyId) != 0;
}

/// Before a step: each closed soft body (closed[i] != 0) within reach of another soft body gets a proxy shaped like
/// its surface where it is now, moving as it moves; the others lose theirs.
TN_API void tn_soft_proxies(JPH_PhysicsSystem* world, const uint32_t* bodies, const int32_t* closed, const float* reach, uint32_t count)
{
	auto& touches = TouchesOf(world);
	std::vector<JPH::AABox> bounds(count);
	std::vector<bool> awake(count, false);
	for (uint32_t i = 0; i < count; i++)
	{
		JPH::BodyLockRead lock(Locks(world), JPH::BodyID(bodies[i]));
		if (!lock.Succeeded())
			continue;
		bounds[i] = lock.GetBody().GetWorldSpaceBounds();
		bounds[i].ExpandBy(JPH::Vec3::sReplicate(reach[i]));
		awake[i] = lock.GetBody().IsActive();
	}
	for (uint32_t i = 0; i < count; i++)
	{
		bool near = false;
		for (uint32_t j = 0; j < count && closed[i] != 0 && !near; j++)
			near = j != i && (awake[i] || awake[j]) && bounds[i].Overlaps(bounds[j]);
		std::lock_guard<std::mutex> guard(touches.mutex);
		auto found = touches.proxies.find(bodies[i]);
		if (!near)
		{
			if (found != touches.proxies.end())
			{
				RemoveProxy(world, found->second);
				touches.proxies.erase(found);
			}
			continue;
		}

		// The surface where it is now, about its middle, and how fast it moves as a whole.
		JPH::VertexList points;
		JPH::IndexedTriangleList triangles;
		JPH::RVec3 middle;
		JPH::Vec3 velocity = JPH::Vec3::sZero();
		JPH::ObjectLayer layer;
		{
			JPH::BodyLockRead lock(Locks(world), JPH::BodyID(bodies[i]));
			if (!lock.Succeeded())
				continue;
			const JPH::Body& body = lock.GetBody();
			auto* soft = Soft(const_cast<JPH::Body&>(body));
			const JPH::Mat44 turn = body.GetCenterOfMassTransform().GetRotation();
			middle = body.GetCenterOfMassPosition();
			layer = body.GetObjectLayer();
			for (const auto& vertex : soft->GetVertices())
			{
				points.push_back(JPH::Float3());
				(turn * vertex.mPosition).StoreFloat3(&points.back());
				velocity += vertex.mVelocity;
			}
			velocity = turn.Multiply3x3(velocity / float(std::max<size_t>(points.size(), 1)));
			for (const auto& face : soft->GetSettings()->mFaces)
				triangles.push_back(JPH::IndexedTriangle(face.mVertex[0], face.mVertex[1], face.mVertex[2]));
		}
		JPH::MeshShapeSettings mesh(std::move(points), std::move(triangles));
		auto made = mesh.Create();
		if (made.HasError())
			continue;
		if (found == touches.proxies.end())
		{
			JPH::BodyCreationSettings settings(made.Get(), middle, JPH::Quat::sIdentity(), JPH::EMotionType::Kinematic, layer);
			settings.mOverrideMassProperties = JPH::EOverrideMassProperties::MassAndInertiaProvided;
			settings.mMassPropertiesOverride.mMass = 1.0f;
			settings.mMassPropertiesOverride.mInertia = JPH::Mat44::sIdentity();
			settings.mCollisionGroup = JPH::CollisionGroup(Groups(), bodies[i], SoftGroups::Proxy);
			settings.mAllowSleeping = false;
			const JPH::BodyID proxy = Bodies(world).CreateAndAddBody(settings, JPH::EActivation::Activate);
			if (proxy.IsInvalid())
				continue;
			touches.proxies[bodies[i]] = proxy.GetIndexAndSequenceNumber();
			tn_physics_set_debris(proxy.GetIndexAndSequenceNumber(), true);
			std::lock_guard<std::mutex> proxyGuard(gProxyMutex);
			gProxies.insert(proxy.GetIndexAndSequenceNumber());
		}
		else
		{
			const JPH::BodyID proxy(found->second);
			Bodies(world).SetShape(proxy, made.Get(), false, JPH::EActivation::Activate);
			Bodies(world).SetPositionAndRotation(proxy, middle, JPH::Quat::sIdentity(), JPH::EActivation::Activate);
			Bodies(world).SetLinearVelocity(proxy, velocity);
		}
	}
}

namespace
{

/// Rope.bf's settings, in the same order.
struct RopeConfig
{
	float mass;          // the whole rope's mass (kg), shared by its free points
	float stretch;       // compliance of each length of rope (0 does not stretch)
	float bend;          // compliance of bending and twisting where lengths meet
	float damping;
	float friction;
	float restitution;
	float gravityFactor;
	float radius;        // half its thickness: how far from its line it keeps other things
	int32_t iterations;
	uint32_t layer;
	uint64_t userData;
};

} // namespace

/// Makes a rope: points along it (x, y, z each, in the world, relative to `center`), the first and last held where
/// pinned says (1 held, 0 free). Each length between points is a Cosserat rod: it keeps its length and resists
/// bending and twisting against the next. Returns the body's id, or 0xFFFFFFFF.
TN_API uint32_t tn_rope_create(JPH_PhysicsSystem* world, const RopeConfig* config, const float* positions, uint32_t count, const float* pinned, const float* center)
{
	if (!world || !config || !positions || count < 2)
		return 0xFFFFFFFFu;
	uint32_t free = 0;
	for (uint32_t i = 0; i < count; i++)
		free += (pinned && pinned[i] >= 0.5f) ? 0 : 1;
	const float inverseMass = free > 0 ? float(free) / std::max(config->mass, 0.001f) : 1.0f;
	JPH::Ref<JPH::SoftBodySharedSettings> shared = new JPH::SoftBodySharedSettings();
	for (uint32_t i = 0; i < count; i++)
	{
		JPH::SoftBodySharedSettings::Vertex vertex;
		vertex.mPosition = JPH::Float3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
		vertex.mInvMass = (pinned && pinned[i] >= 0.5f) ? 0.0f : inverseMass;
		shared->mVertices.push_back(vertex);
		if (i > 0)
			shared->mRodStretchShearConstraints.push_back(JPH::SoftBodySharedSettings::RodStretchShear(i - 1, i, std::max(config->stretch, 0.0f)));
		if (i > 1)
			shared->mRodBendTwistConstraints.push_back(JPH::SoftBodySharedSettings::RodBendTwist(i - 2, i - 1, std::max(config->bend, 0.0f)));
	}
	shared->CalculateRodProperties();
	// From each held end, no point gets further away than the rope between them is long: a long rope holding
	// weight does not stretch however few passes the solver makes.
	for (uint32_t end : { 0u, count - 1 })
	{
		if (!pinned || pinned[end] < 0.5f)
			continue;
		float along = 0;
		for (uint32_t step = 1; step < count; step++)
		{
			const uint32_t i = end == 0 ? step : count - 1 - step;
			const uint32_t before = end == 0 ? i - 1 : i + 1;
			along += (JPH::Vec3(shared->mVertices[i].mPosition) - JPH::Vec3(shared->mVertices[before].mPosition)).Length();
			if (pinned[i] >= 0.5f)
				continue;
			JPH::SoftBodySharedSettings::LRA reach(end, i, along);
			shared->mLRAConstraints.push_back(reach);
		}
	}
	shared->Optimize();

	JPH::SoftBodyCreationSettings settings(shared, JPH::RVec3(center[0], center[1], center[2]), JPH::Quat::sIdentity(), (JPH::ObjectLayer)config->layer);
	settings.mUserData = config->userData;
	settings.mNumIterations = (JPH::uint32)std::clamp(config->iterations, 1, 64);
	settings.mLinearDamping = std::max(config->damping, 0.0f);
	settings.mFriction = std::max(config->friction, 0.0f);
	settings.mRestitution = std::clamp(config->restitution, 0.0f, 1.0f);
	settings.mGravityFactor = config->gravityFactor;
	settings.mVertexRadius = std::max(config->radius, 0.0f);
	settings.mUpdatePosition = true;
	settings.mMakeRotationIdentity = true;
	settings.mAllowSleeping = true;
	TouchesOf(world);
	const JPH::BodyID id = Bodies(world).CreateAndAddSoftBody(settings, JPH::EActivation::Activate);
	if (id.IsInvalid())
		return 0xFFFFFFFFu;
	{
		auto& touches = TouchesOf(world);
		std::lock_guard<std::mutex> guard(touches.mutex);
		touches.ropes[id.GetIndexAndSequenceNumber()];
	}
	JPH::BodyLockWrite lock(Locks(world), id);
	if (lock.Succeeded())
		lock.GetBody().SetCollisionGroup(JPH::CollisionGroup(Groups(), id.GetIndexAndSequenceNumber(), SoftGroups::Open));
	return id.GetIndexAndSequenceNumber();
}

/// Ties two bodies (0xFFFFFFFF for a point fixed in the world) so that their points (in the world, as they are now)
/// get no further apart than `length`: the rope's pull. Returns the tie, for tn_rope_untie.
TN_API void* tn_rope_tie(JPH_PhysicsSystem* world, uint32_t bodyA, const float* pointA, uint32_t bodyB, const float* pointB, float length)
{
	auto* system = reinterpret_cast<JoltcSystem*>(world)->physicsSystem;
	JPH::DistanceConstraintSettings settings;
	settings.mSpace = JPH::EConstraintSpace::WorldSpace;
	settings.mPoint1 = JPH::RVec3(pointA[0], pointA[1], pointA[2]);
	settings.mPoint2 = JPH::RVec3(pointB[0], pointB[1], pointB[2]);
	settings.mMinDistance = 0;
	settings.mMaxDistance = std::max(length, 0.001f);
	JPH::BodyID ids[2] = { JPH::BodyID(bodyA), JPH::BodyID(bodyB) };
	JPH::BodyLockMultiWrite lock(system->GetBodyLockInterface(), ids, 2);
	JPH::Body* a = bodyA == 0xFFFFFFFFu ? &JPH::Body::sFixedToWorld : lock.GetBody(0);
	JPH::Body* b = bodyB == 0xFFFFFFFFu ? &JPH::Body::sFixedToWorld : lock.GetBody(1);
	if (a == nullptr || b == nullptr || a == b)
		return nullptr;
	JPH::TwoBodyConstraint* tie = settings.Create(*a, *b);
	tie->AddRef();
	system->AddConstraint(tie);
	return tie;
}

/// The points where a rope (tn_rope_create) bends round something: points touching it on the far side from the
/// straight line between `start` and `end` (so a rope over a beam, not one lying along the floor). Writes the first
/// and last of them, in order along the rope, to `first` and `last`, and their places (x, y, z each, in the world)
/// to `places`; returns false when it bends round nothing.
TN_API bool tn_rope_wraps(JPH_PhysicsSystem* world, uint32_t bodyId, const float* start, const float* end, float clearance, uint32_t* first, uint32_t* last, float* places)
{
	JPH::BodyLockRead lock(Locks(world), JPH::BodyID(bodyId));
	if (!lock.Succeeded() || !lock.GetBody().IsSoftBody())
		return false;
	const JPH::Body& body = lock.GetBody();
	const auto* soft = static_cast<const JPH::SoftBodyMotionProperties*>(body.GetMotionProperties());
	const JPH::Mat44 toWorld = body.GetCenterOfMassTransform().ToMat44();
	const JPH::Vec3 a(start[0], start[1], start[2]), b(end[0], end[1], end[2]);
	const JPH::Vec3 chord = b - a;
	const float chordLength = chord.LengthSq();
	const auto& vertices = soft->GetVertices();
	// Which way each point was last pushed off something (the step clears Jolt's own record when it ends).
	auto& touches = TouchesOf(world);
	std::vector<JPH::Vec3> pushed;
	{
		std::lock_guard<std::mutex> guard(touches.mutex);
		auto found = touches.ropes.find(bodyId);
		if (found == touches.ropes.end() || found->second.size() != vertices.size())
			return false;
		pushed = found->second;
		std::fill(found->second.begin(), found->second.end(), JPH::Vec3::sZero());
	}
	int32_t found[2] = { -1, -1 };
	for (uint32_t i = 1; i + 1 < (uint32_t)vertices.size(); i++)
	{
		const auto& vertex = vertices[i];
		if (pushed[i].IsNearZero())
			continue;
		const JPH::Vec3 at = toWorld * vertex.mPosition;
		const float t = chordLength > 1.0e-8f ? std::clamp((at - a).Dot(chord) / chordLength, 0.0f, 1.0f) : 0.0f;
		const JPH::Vec3 off = at - (a + chord * t);
		const JPH::Vec3 normal = toWorld.Multiply3x3(pushed[i]);
		if (off.Length() < clearance || normal.Dot(off) <= 0)
			continue;
		if (found[0] < 0)
			found[0] = (int32_t)i;
		found[1] = (int32_t)i;
	}
	if (found[0] < 0)
		return false;
	*first = (uint32_t)found[0];
	*last = (uint32_t)found[1];
	for (int k = 0; k < 2; k++)
	{
		const JPH::Vec3 at = toWorld * vertices[found[k]].mPosition;
		places[k * 3] = at.GetX();
		places[k * 3 + 1] = at.GetY();
		places[k * 3 + 2] = at.GetZ();
	}
	return true;
}

/// Ties two bodies (0xFFFFFFFF for a point fixed in the world) over two fixed points, as a rope over a pulley: the
/// rope from pointA to fixedA and from fixedB to pointB together get no longer than `length`.
TN_API void* tn_rope_tie_over(JPH_PhysicsSystem* world, uint32_t bodyA, const float* pointA, const float* fixedA, uint32_t bodyB, const float* pointB, const float* fixedB, float length)
{
	auto* system = reinterpret_cast<JoltcSystem*>(world)->physicsSystem;
	JPH::PulleyConstraintSettings settings;
	settings.mSpace = JPH::EConstraintSpace::WorldSpace;
	settings.mBodyPoint1 = JPH::RVec3(pointA[0], pointA[1], pointA[2]);
	settings.mFixedPoint1 = JPH::RVec3(fixedA[0], fixedA[1], fixedA[2]);
	settings.mBodyPoint2 = JPH::RVec3(pointB[0], pointB[1], pointB[2]);
	settings.mFixedPoint2 = JPH::RVec3(fixedB[0], fixedB[1], fixedB[2]);
	settings.mMinLength = 0;
	settings.mMaxLength = std::max(length, 0.001f);
	JPH::BodyID ids[2] = { JPH::BodyID(bodyA), JPH::BodyID(bodyB) };
	JPH::BodyLockMultiWrite lock(system->GetBodyLockInterface(), ids, 2);
	JPH::Body* a = bodyA == 0xFFFFFFFFu ? &JPH::Body::sFixedToWorld : lock.GetBody(0);
	JPH::Body* b = bodyB == 0xFFFFFFFFu ? &JPH::Body::sFixedToWorld : lock.GetBody(1);
	if (a == nullptr || b == nullptr || a == b)
		return nullptr;
	JPH::TwoBodyConstraint* tie = settings.Create(*a, *b);
	tie->AddRef();
	system->AddConstraint(tie);
	return tie;
}

/// Lets go of a tie (tn_rope_tie, tn_rope_tie_over).
TN_API void tn_rope_untie(JPH_PhysicsSystem* world, void* tie)
{
	if (!tie)
		return;
	auto* constraint = static_cast<JPH::TwoBodyConstraint*>(tie);
	reinterpret_cast<JoltcSystem*>(world)->physicsSystem->RemoveConstraint(constraint);
	constraint->Release();
}

/// How hard a tie pulled in its last step, in newtons.
TN_API float tn_rope_pull(void* tie, float step)
{
	if (!tie || step <= 0)
		return 0;
	auto* constraint = static_cast<JPH::TwoBodyConstraint*>(tie);
	if (constraint->GetSubType() == JPH::EConstraintSubType::Pulley)
		return std::abs(static_cast<JPH::PulleyConstraint*>(tie)->GetTotalLambdaPosition()) / step;
	return std::abs(static_cast<JPH::DistanceConstraint*>(tie)->GetTotalLambdaPosition()) / step;
}
