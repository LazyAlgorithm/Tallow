// Rapier3D through the C bindings (third_party/rapier). The narrow ABI in tallow_rapier.h keeps Rapier's large
// descriptors and handle lifetimes on this side. Compiled only when the prebuilt archive for the target is present;
// the stub in tallow_rapier_stub.c keeps builds without it linking (tn_rapier_available returns 0, the provider stays
// unlisted).
#include "tallow_rapier.h"

#ifndef RAPIER_STATIC
#define RAPIER_STATIC
#endif
#include "rapier.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <cstdlib>
#include <limits>

// Reads an environment variable (std::getenv is "deprecated" by MSVC's CRT headers; this is not).
static bool EnvironmentSet(const char* name, char* out, size_t size)
{
#if defined(_WIN32)
	size_t length = 0;
	return getenv_s(&length, out, size, name) == 0 && length > 0;
#else
	const char* value = std::getenv(name);
	if (value == nullptr)
		return false;
	std::snprintf(out, size, "%s", value);
	return true;
#endif
}

namespace
{
	const uint32_t NoBody = 0xffffffffu;
	constexpr float CharacterContactOffset = 0.01f;
	const uint64_t SoftColliderTag = 0x54414c4c4f575342ull;
	// ProjectConfig.MaxLayers: PhysicsLayerTable packs the project layer in the low bits.
	const uint32_t LayerCount = 32;
	const size_t MaxGeometryFloats = 18000000;

	inline bool Valid(R3RigidBodyHandle h) { return h.index != UINT32_MAX; }
	inline bool Valid(R3ColliderHandle h) { return h.index != UINT32_MAX; }
	inline bool Valid(R3ImpulseJointHandle h) { return h.index != UINT32_MAX; }
	inline bool Valid(R3SoftBodyHandle h) { return h.index != UINT32_MAX; }
	inline bool Same(const R3ColliderHandle& a, const R3ColliderHandle& b)
	{
		return a.index == b.index && a.generation == b.generation && a.world == b.world;
	}
	inline bool Same(const R3SoftBodyHandle& a, const R3SoftBodyHandle& b)
	{
		return a.index == b.index && a.generation == b.generation && a.world == b.world;
	}

	inline R3Vector V(float x, float y, float z) { return R3Vector{x, y, z}; }
	inline R3Vector V(const float v[3]) { return R3Vector{v[0], v[1], v[2]}; }
	inline R3Rotation Q(const float v[4]) { return R3Rotation{v[0], v[1], v[2], v[3]}; }
	inline R3Pose Pose(const float p[3], const float r[4]) { return R3Pose{V(p), Q(r)}; }

	inline R3Vector Add(R3Vector a, R3Vector b) { return V(a.x + b.x, a.y + b.y, a.z + b.z); }
	inline R3Vector Sub(R3Vector a, R3Vector b) { return V(a.x - b.x, a.y - b.y, a.z - b.z); }
	inline R3Vector Scale(R3Vector a, float s) { return V(a.x * s, a.y * s, a.z * s); }
	inline float Dot(R3Vector a, R3Vector b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
	inline R3Vector Cross(R3Vector a, R3Vector b)
	{
		return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
	}
	inline float Length(R3Vector a) { return std::sqrt(Dot(a, a)); }
	inline R3Vector Normalize(R3Vector a)
	{
		const float len = Length(a);
		return len > 1.0e-9f ? Scale(a, 1.0f / len) : V(0, 0, 0);
	}
	inline void Out(float out[3], R3Vector v) { out[0] = v.x; out[1] = v.y; out[2] = v.z; }

	inline R3Rotation QMul(R3Rotation a, R3Rotation b)
	{
		return R3Rotation{
			a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
			a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
			a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
			a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z};
	}
	inline R3Rotation QConj(R3Rotation a) { return R3Rotation{-a.x, -a.y, -a.z, a.w}; }
	inline R3Rotation QNorm(R3Rotation a)
	{
		const float len = std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z + a.w * a.w);
		if (len < 1.0e-9f)
			return R3Rotation{0, 0, 0, 1};
		const float s = 1.0f / len;
		return R3Rotation{a.x * s, a.y * s, a.z * s, a.w * s};
	}
	inline R3Vector QRot(R3Rotation q, R3Vector v)
	{
		const R3Vector u{q.x, q.y, q.z};
		const R3Vector t = Scale(Cross(u, v), 2.0f);
		return Add(Add(v, Scale(t, q.w)), Cross(u, t));
	}
	// The rotation that turns +X onto `axis`.
	inline R3Rotation AlignX(R3Vector axis)
	{
		axis = Normalize(axis);
		if (Length(axis) < 1.0e-6f)
			return R3Rotation{0, 0, 0, 1};
		const float d = axis.x;
		if (d > 0.999999f)
			return R3Rotation{0, 0, 0, 1};
		if (d < -0.999999f)
			return R3Rotation{0, 0, 1, 0};
		const R3Vector cross = V(0.0f, axis.z, -axis.y);
		return QNorm(R3Rotation{cross.x, cross.y, cross.z, 1.0f + d});
	}

	struct PartInfo
	{
		int32_t kind = TN_RAPIER_BOX;
		bool trimesh = false;
	};

	struct Body
	{
		R3RigidBodyHandle handle{};
		std::vector<R3ColliderHandle> colliders;
		std::vector<PartInfo> parts;
		int32_t motion = 0;
		int32_t motionClass = 0;
		uint32_t objectCode = 0;
		uint32_t group = 0;
		uint32_t memberships = 0xffffffffu;
		uint32_t filter = 0xffffffffu;
		bool debris = false;
		bool sensor = false;
		bool hasStepForce = false;
		bool hasStepTorque = false;
		R3ColliderHandle shellSurface{nullptr, UINT32_MAX, 0};
		uint64_t userData = 0;
		// Velocities at the start of the last step, for impacts the solver has already stopped by the time contacts
		// are read (a stiff soft-body shell stops a projectile in one step).
		R3Vector prevLinear = V(0, 0, 0);
		R3Vector prevAngular = V(0, 0, 0);
		R3Vector prevPrevLinear = V(0, 0, 0);
		R3Vector prevPrevPrevLinear = V(0, 0, 0);
	};

	inline uint32_t ColliderKey(R3ColliderHandle h) { return h.index ^ (h.generation * 0x9e3779b1u); }


	// A collider pair by exact handles (index and generation of each, smaller first), for sorting and merging.
	struct ExactPair
	{
		uint64_t first, second;
		bool operator<(const ExactPair& o) const { return first != o.first ? first < o.first : second < o.second; }
		bool operator==(const ExactPair& o) const { return first == o.first && second == o.second; }
	};
	inline uint64_t ExactCollider(R3ColliderHandle h) { return ((uint64_t)h.index << 32) | h.generation; }
	inline ExactPair MakeExactPair(R3ColliderHandle a, R3ColliderHandle b)
	{
		const uint64_t ka = ExactCollider(a), kb = ExactCollider(b);
		return ka <= kb ? ExactPair{ka, kb} : ExactPair{kb, ka};
	}

	struct ActivePair
	{
		ExactPair key{};
		R3ColliderHandle a{}, b{};
		uint32_t bodyA = NoBody, bodyB = NoBody;
		uint64_t objectA = 0, objectB = 0;
		bool sensor = false;
	};

	struct HitRecord
	{
		uint32_t body;
		uint32_t subshape;
		R3Vector point;
		R3Vector normal;
		int32_t part;
		int32_t triangle;
	};

	struct Joint
	{
		R3ImpulseJointHandle handle{};
		int32_t kind = 0;
		uint32_t bodyA = NoBody, bodyB = NoBody;
		R3Pose frame1{}, frame2{};
		R3Vector worldAxis = V(1, 0, 0);
		bool hasFrame = true;
	};

	struct Character;

	struct RopeTie
	{
		R3ImpulseJointHandle joint{};
		R3RigidBodyHandle anchor{};
		bool hasAnchor = false;
	};

	struct SoftBody
	{
		R3SoftBodyHandle handle{};
		Body collisionInfo;
		bool hasCollider = false;
		R3ColliderHandle replacedCollider{nullptr, UINT32_MAX, 0};
		bool hasCarrierMassProperties = false;
		std::unordered_set<uint32_t> dentedContacts;
		bool attachedToCarrier = false;
		int32_t count = 0;
		uint64_t userData = 0;
		int32_t kind = 0;
		int32_t impacts = 0;
		bool visualOnly = false;
		bool tear = false;
		bool hasInteriorParticle = false;
		float dentDepth = 0, dentYield = 0, dentSpeed = 0;
		R3Vector drivenCenter{};
		float drivenBindInverse[16] = {};
		float restVolume = 1;
		float totalMass = 1;
		float particleMass = 1;
		float radius = 0.02f;
		std::vector<uint32_t> triangles;
		std::vector<R3Vector> restLocal;
		// Outward surface normal at each rest vertex, in the object's space (area-weighted, made when first needed).
		std::vector<R3Vector> restNormal;
		// Mean rest edge length in the object's space (with restNormal): the finest dent the mesh can show.
		float restEdge = 0;
		// A FromImpacts shell's permanent dents, in its object's local space. They are held to the object each step;
		// the soft body's own sag or blob motion is not a dent.
		std::vector<R3Vector> dents;
		std::vector<size_t> pendingDentVertices;
		float lastObject[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
		bool hasObject = false;
		bool followsDynamicBody = false;
		float objectFromBody[16] = {};
		uint32_t ignoredBody = NoBody;
		uint32_t secondRopeEnd = NoBody;
		R3ColliderHandle deformable{nullptr, UINT32_MAX, 0};
		float friction = 0.5f;
		uint32_t dentRevision = 0;
		float lastDentSum = 0;
		bool torn = false;
	};

	struct Vehicle
	{
		R3DynamicRayCastVehicleController* controller = nullptr;
		R3RigidBodyHandle chassis{};
		uint32_t chassisId = NoBody;
		std::vector<TnRapierWheel> wheels;
		R3Vector up = V(0, 1, 0);
		R3Vector forward = V(0, 0, 1);
		float maxTorque = 0, minRPM = 0, maxRPM = 6000;
		std::vector<float> gears;
		float reverseRatio = 1;
		float inputForward = 0, inputRight = 0, inputBrake = 0, inputHandBrake = 0;
		int32_t gear = 1;
		float rpm = 0, ratio = 1;
		std::vector<float> lastRotation;
		std::vector<float> wheelSpeed;
		std::vector<float> steer;
	};

	struct World
	{
		R3World* world = nullptr;
		R3EventCollector* events = nullptr;
		std::unordered_map<uint32_t, Body> bodies;
		std::unordered_map<uint32_t, Joint*> joints;
		std::unordered_map<uint32_t, Character*> characters;
		std::unordered_map<uint32_t, Vehicle*> vehicles;
		std::unordered_map<uint32_t, SoftBody*> softBodies;
		std::unordered_map<uint32_t, RopeTie*> ropeTies;
		// Deformable shell colliders are owned by the soft-body root; queries and contacts name the shell object.
		std::unordered_map<uint32_t, uint32_t> deformableOwners;
		uint32_t nextId = 1;
		bool contactEvents = false;
		uint32_t queryWorlds = 0xffffffffu;
		// Queries are stale until refreshed: queryMoved names the bodies moved or created since (a cheap refresh);
		// queryFull asks for a whole collision-detection pass (structural changes, which are rare).
		bool queryDirty = false;
		bool queryFull = false;
		std::vector<R3RigidBodyHandle> queryMoved;

		void MarkQueryMoved(R3RigidBodyHandle handle)
		{
			queryMoved.push_back(handle);
			queryDirty = true;
		}
		void MarkQueryFull()
		{
			queryFull = true;
			queryDirty = true;
		}
		// Pairs reported as touching, sorted by key (merged with each tick's pairs to find begins and ends).
		std::vector<ActivePair> activePairList;
		std::vector<TnRapierContact> contacts;
		std::vector<HitRecord> recentHits;
		size_t recentHitNext = 0;
		// Bodies given a one-step force or torque since the last step (Rapier's accumulators persist).
		std::vector<uint32_t> forcedBodies;
		// Reused by tn_rapier_contacts each tick.
		std::vector<R3ContactSummary> contactSummaryScratch;
		std::vector<R3IntersectionPair> intersectionPairScratch;
		// A touching pair this tick: its colliders and, for solid contacts, its summary (nullptr for sensors).
		struct CurrentPair
		{
			ExactPair key;
			R3ColliderHandle a, b;
			const R3ContactSummary* summary;
			bool operator<(const CurrentPair& o) const { return key < o.key; }
		};
		std::vector<CurrentPair> currentPairScratch;
		std::vector<ActivePair> nowPairScratch;
		// Contact bookkeeping per collider (owning body id without deformable remapping, sensor flag), keyed by the
		// exact handle. A collider's parent and sensor flag never change, and a removed collider's handle is never
		// reused with the same generation, so entries only go stale; the map is cleared when it grows large.
		struct ColliderInfo
		{
			uint32_t body;
			bool sensor;
		};
		std::unordered_map<uint64_t, ColliderInfo> colliderInfo;
		// Awake bodies for the contact pass, from one r3ActiveRigidBodies call per tick.
		std::vector<R3RigidBodyHandle> activeBodyScratch;
		std::unordered_set<uint64_t> awakeScratch;

		void MarkStepForce(uint32_t id, Body& body, bool force, bool torque)
		{
			if (!body.hasStepForce && !body.hasStepTorque && (force || torque))
				forcedBodies.push_back(id);
			body.hasStepForce |= force;
			body.hasStepTorque |= torque;
		}

		Body* Find(uint32_t id)
		{
			auto it = bodies.find(id);
			return it == bodies.end() ? nullptr : &it->second;
		}
		const Body* Find(uint32_t id) const
		{
			auto it = bodies.find(id);
			return it == bodies.end() ? nullptr : &it->second;
		}
		const Body* FindCollision(uint32_t id) const
		{
			if (const Body* rigid = Find(id))
				return rigid;
			auto soft = softBodies.find(id);
			return soft != softBodies.end() && soft->second->hasCollider ? &soft->second->collisionInfo : nullptr;
		}
		uint32_t BodyOf(R3ColliderHandle collider)
		{
			if (!Valid(collider))
				return NoBody;
			const R3RigidBodyHandle parent = r3Collider_Parent(collider);
			if (!Valid(parent))
				return NoBody;
			return (uint32_t)r3RigidBody_UserData(parent).low;
		}
		void RememberHit(uint32_t body, uint32_t subshape, R3Vector point, R3Vector normal, int32_t part, int32_t triangle)
		{
			HitRecord record;
			record.body = body;
			record.subshape = subshape;
			record.point = point;
			record.normal = normal;
			record.part = part;
			record.triangle = triangle;
			// A ring of the last 256 hits; recentHitNext is the slot the next hit overwrites once it is full.
			if (recentHits.size() < 256)
				recentHits.push_back(record);
			else
				recentHits[recentHitNext] = record;
			recentHitNext = (recentHitNext + 1) % 256;
		}
	};

	uint32_t DeformableOwner(const World* world, R3ColliderHandle collider)
	{
		if (world == nullptr || !Valid(collider))
			return NoBody;
		auto it = world->deformableOwners.find(ColliderKey(collider));
		return it == world->deformableOwners.end() ? NoBody : it->second;
	}

	struct Character
	{
		R3RigidBodyHandle body{};
		R3ColliderHandle collider{};
		R3KinematicCharacterController* controller = nullptr;
		R3SharedShape* shape = nullptr;
		std::vector<PartInfo> parts;
		uint32_t bodyId = NoBody;
		uint32_t objectCode = 0;
		uint32_t group = 0;
		uint32_t memberships = 0xffffffffu;
		uint32_t filter = 0xffffffffu;
		uint64_t userData = 0;
		float maxSlope = 0.7853982f;
		float mass = 1.0f;
		float pushStrength = 100.0f;
		float supportHeight = 0.1f;
		R3Vector position = V(0, 0, 0);
		R3Rotation rotation = R3Rotation{0, 0, 0, 1};
		R3Vector shapeCenter = V(0, 0, 0);
		R3Vector velocity = V(0, 0, 0);
		std::vector<TnRapierCharacterHit> lastHits;
		std::vector<R3Vector> lastHitPoints;
		std::vector<R3Vector> lastHitNormals;
	};

	// ---- shape building ----

	bool FillShapeDesc(R3ShapeDesc& desc, const TnRapierPart& part)
	{
		desc = r3DefaultShapeDesc();
		switch (part.kind)
		{
		case TN_RAPIER_BOX:
			desc.kind = R3_SHAPE_DESC_CUBOID;
			desc.a = V(part.half);
			return true;
		case TN_RAPIER_SPHERE:
			desc.kind = R3_SHAPE_DESC_BALL;
			desc.radius = std::max(part.radius, 0.0001f);
			return true;
		case TN_RAPIER_CAPSULE:
			desc.kind = R3_SHAPE_DESC_CAPSULE;
			desc.a = V(0, -std::max(part.halfHeight, 0.0f), 0);
			desc.b = V(0, std::max(part.halfHeight, 0.0f), 0);
			desc.radius = std::max(part.radius, 0.0001f);
			return true;
		case TN_RAPIER_CYLINDER:
			desc.kind = R3_SHAPE_DESC_CYLINDER;
			desc.halfHeight = std::max(part.halfHeight, 0.0001f);
			desc.radius = std::max(part.radius, 0.0001f);
			return true;
		case TN_RAPIER_CONVEX:
			if (part.vertexCount < 4 || part.vertices == nullptr)
				return false;
			desc.kind = R3_SHAPE_DESC_CONVEX_HULL;
			desc.vertices = R3VectorView{reinterpret_cast<const R3Vector*>(part.vertices), (size_t)part.vertexCount};
			return true;
		case TN_RAPIER_TRIMESH:
			if (part.vertexCount < 3 || part.vertices == nullptr || part.indices == nullptr || part.indexCount < 3)
				return false;
			desc.kind = R3_SHAPE_DESC_TRIMESH;
			desc.vertices = R3VectorView{reinterpret_cast<const R3Vector*>(part.vertices), (size_t)part.vertexCount};
			desc.triangles = R3TriangleView{reinterpret_cast<const R3Triangle*>(part.indices), (size_t)part.indexCount / 3};
			return true;
		default:
			return false;
		}
	}

	R3SharedShape* BuildShape(const TnRapierPart& part)
	{
		R3ShapeDesc desc;
		if (!FillShapeDesc(desc, part))
			return nullptr;
		return r3ShapeDesc_Build(&desc);
	}

	// ---- query filtering ----

	struct QueryContext
	{
		const World* world = nullptr;
		uint32_t layerMask = 0xffffffffu;
		uint32_t ignoreBody = NoBody;
		uint32_t onlyBody = NoBody;
		uint32_t memberships = 0xffffffffu;
		uint32_t filter = 0xffffffffu;
		bool groupFilter = false;
		bool excludeSensors = false;
		bool excludeSoftBodies = false;
		const std::vector<R3ColliderHandle>* excluded = nullptr;
	};

	bool AcceptBody(const QueryContext& c, const Body& body, uint32_t id)
	{
		if (id == c.ignoreBody)
			return false;
		if (c.onlyBody != NoBody && id != c.onlyBody)
			return false;
		const uint32_t layer = body.objectCode % LayerCount;
		if ((c.layerMask & (1u << layer)) == 0)
			return false;
		if (c.groupFilter)
		{
			if ((c.memberships & body.filter) == 0 || (body.memberships & c.filter) == 0)
				return false;
		}
		if (c.world != nullptr && c.world->queryWorlds != 0xffffffffu && body.group != 0 && (body.group & c.world->queryWorlds) == 0)
			return false;
		return true;
	}

	R3Bool RAPIER_CALL QueryPredicate(void* user, const R3ReadContext* read, R3ColliderHandle collider)
	{
		const QueryContext* c = static_cast<const QueryContext*>(user);
		if (c == nullptr || c->world == nullptr)
			return 0;
		if (c->excluded != nullptr)
		{
			for (const R3ColliderHandle& handle : *c->excluded)
			{
				if (Same(handle, collider))
					return 0;
			}
		}
		if (c->excludeSensors && r3ReadCollider_IsSensor(read, collider))
			return 0;
		uint32_t id = DeformableOwner(c->world, collider);
		const R3UserData colliderData = r3ReadCollider_UserData(read, collider);
		if (id == NoBody && colliderData.high == SoftColliderTag)
		{
			if (c->excludeSoftBodies)
				return 0;
			id = (uint32_t)colliderData.low;
		}
		if (id == NoBody)
		{
			const R3RigidBodyHandle parent = r3ReadCollider_Parent(read, collider);
			if (!Valid(parent))
				return 0;
			id = (uint32_t)r3ReadRigidBody_UserData(read, parent).low;
		}
		const Body* body = c->world->FindCollision(id);
		if (body == nullptr)
			return 0;
		if (Valid(body->shellSurface) && !Same(body->shellSurface, collider))
			return 0;
		return AcceptBody(*c, *body, id) ? 1 : 0;
	}

	R3QueryOptions Options(const QueryContext& context)
	{
		R3QueryOptions options = r3DefaultQueryOptions();
		options.predicate = &QueryPredicate;
		options.userData = const_cast<QueryContext*>(&context);
		if (context.ignoreBody != NoBody)
		{
			const Body* body = context.world->Find(context.ignoreBody);
			if (body != nullptr)
				options.filter.exclude_rigid_body = body->handle;
		}
		return options;
	}

	// ---- pair filter hook ----

	bool ShareWorld(const Body& a, const Body& b)
	{
		return a.group == 0 || b.group == 0 || (a.group & b.group) != 0;
	}

	bool DebrisPasses(const Body& a, const Body& b)
	{
		const int32_t debrisClass = 2, movingClass = 1;
		if (a.debris || a.motionClass == debrisClass)
		{
			if (b.motionClass == movingClass || b.debris || b.motionClass == debrisClass)
				return false;
		}
		if (b.debris || b.motionClass == debrisClass)
		{
			if (a.motionClass == movingClass || a.debris || a.motionClass == debrisClass)
				return false;
		}
		return true;
	}

	int32_t RAPIER_CALL FilterPair(void* user, const R3ReadContext* read, R3ColliderHandle c1, R3ColliderHandle c2,
		R3RigidBodyHandle b1, R3RigidBodyHandle b2)
	{
		const World* world = static_cast<const World*>(user);
		if (world == nullptr)
			return 1;
		const uint32_t id1 = (uint32_t)r3ReadRigidBody_UserData(read, b1).low;
		const uint32_t id2 = (uint32_t)r3ReadRigidBody_UserData(read, b2).low;
		auto soft1 = world->softBodies.find(id1);
		auto soft2 = world->softBodies.find(id2);
		if ((soft1 != world->softBodies.end() && (soft1->second->ignoredBody == id2 || soft1->second->secondRopeEnd == id2)) ||
			(soft2 != world->softBodies.end() && (soft2->second->ignoredBody == id1 || soft2->second->secondRopeEnd == id1)))
			return -1;
		const Body* rigidA = world->Find(id1);
		const Body* rigidB = world->Find(id2);
		if ((rigidA != nullptr && Valid(rigidA->shellSurface) && !Same(rigidA->shellSurface, c1)) ||
			(rigidB != nullptr && Valid(rigidB->shellSurface) && !Same(rigidB->shellSurface, c2)))
			return -1;
		const uint32_t ownerA = DeformableOwner(world, c1);
		const uint32_t ownerB = DeformableOwner(world, c2);
		const Body* a = world->FindCollision(ownerA == NoBody ? id1 : ownerA);
		const Body* b = world->FindCollision(ownerB == NoBody ? id2 : ownerB);
		if (a == nullptr && soft1 != world->softBodies.end() && soft1->second->kind == 4)
			a = &soft1->second->collisionInfo;
		if (b == nullptr && soft2 != world->softBodies.end() && soft2->second->kind == 4)
			b = &soft2->second->collisionInfo;
		if (a == nullptr || b == nullptr)
			return 1;
		if (!ShareWorld(*a, *b))
			return -1;
		if (!DebrisPasses(*a, *b))
			return -1;
		return 1;
	}

	// ---- bodies ----

	// FilterPair can only reject a pair for a body in a world group, debris, or a shell carrier (soft-body colliders
	// always carry the hook). Rapier asks the hook when either collider of a pair has it, so plain bodies leave it
	// off and skip a callback per pair per step.
	uint32_t FilterHooksFor(const Body& body)
	{
		const bool needed = body.group != 0 || body.debris || body.motionClass == 2 || Valid(body.shellSurface);
		return needed ? (uint32_t)(R3_FILTER_CONTACT_PAIRS | R3_FILTER_INTERSECTION_PAIR) : 0u;
	}

	void UpdateFilterHooks(Body& body)
	{
		const uint32_t hooks = FilterHooksFor(body);
		for (R3ColliderHandle collider : body.colliders)
			r3Collider_SetActiveHooks(collider, hooks);
	}

	R3ColliderDesc MakeCollider(const TnRapierPart& part, const Body& body, bool sensor, float friction,
		float restitution, float mass, bool hasMass)
	{
		R3ColliderDesc collider = r3DefaultColliderDesc();
		if (!FillShapeDesc(collider.shape, part))
			return collider;
		collider.position = R3Pose{V(part.position), Q(part.rotation)};
		collider.friction = std::max(friction, 0.0f);
		collider.restitution = std::max(restitution, 0.0f);
		collider.isSensor = sensor ? 1 : 0;
		collider.collisionGroups = R3InteractionGroups{body.memberships, body.filter, 0};
		collider.solverGroups = R3InteractionGroups{body.memberships, body.filter, 0};
		collider.activeHooks = FilterHooksFor(body);
		collider.activeEvents = 0; // contacts come from the narrow phase's pair lists
		if (hasMass && mass > 0.0f)
		{
			collider.massMode = R3_MASS_TOTAL;
			collider.mass = mass;
		}
		return collider;
	}

	uint32_t AllocateId(World* world, uint32_t wanted)
	{
		if (wanted != NoBody && world->bodies.count(wanted) == 0 && world->softBodies.count(wanted) == 0)
		{
			if (wanted >= world->nextId)
				world->nextId = wanted + 1;
			return wanted;
		}
		while (world->bodies.find(world->nextId) != world->bodies.end())
			world->nextId++;
		return world->nextId++;
	}

	// ---- contacts ----

	uint32_t BodyIdOfCollider(const World* world, R3ColliderHandle collider)
	{
		if (!Valid(collider))
			return NoBody;
		const uint32_t owner = DeformableOwner(world, collider);
		if (owner != NoBody)
			return owner;
		const R3UserData colliderData = r3Collider_UserData(collider);
		if (colliderData.high == SoftColliderTag)
			return (uint32_t)colliderData.low;
		const R3RigidBodyHandle parent = r3Collider_Parent(collider);
		if (!Valid(parent))
			return NoBody;
		return (uint32_t)r3RigidBody_UserData(parent).low;
	}

	void FillContactGeometry(const World* world, R3ColliderHandle c1, R3ColliderHandle c2, TnRapierContact& contact,
		bool sensor)
	{
		if (!sensor)
		{
			R3ContactPoint points[16];
			const size_t count = r3ContactPoints(c1, c2, points, 16);
			if (count > 0)
			{
				size_t best = 0;
				for (size_t i = 1; i < count; i++)
				{
					if (std::fabs(points[i].impulse) > std::fabs(points[best].impulse))
						best = i;
				}
				// tn_rapier_contacts passes pairs in the narrow phase's own order, so collider 1 is c1.
				const bool flipped = false;
				R3Vector normal = points[best].normal;
				if (flipped)
					normal = Scale(normal, -1.0f);
				contact.normal[0] = normal.x;
				contact.normal[1] = normal.y;
				contact.normal[2] = normal.z;
				// The point is on collider 1's surface; move it to the middle of the pair.
				R3Pose pose1 = r3Collider_Position(c1);
				R3Vector local = flipped ? points[best].local_p2 : points[best].local_p1;
				R3Vector point = Add(pose1.translation, QRot(pose1.rotation, local));
				contact.point[0] = point.x;
				contact.point[1] = point.y;
				contact.point[2] = point.z;
				if (contact.bodyA != NoBody && contact.bodyB != NoBody)
				{
					const Body* a = world->Find(contact.bodyA);
					const Body* b = world->Find(contact.bodyB);
					if (a != nullptr && b != nullptr)
					{
						const R3Vector va = r3RigidBody_VelocityAtPoint(a->handle, point);
						const R3Vector vb = r3RigidBody_VelocityAtPoint(b->handle, point);
						contact.speed = std::fabs(Dot(Sub(vb, va), normal));
					}
				}
				return;
			}
		}
		// Sensors and pairs without a manifold: middle of the two colliders.
		const R3Vector p1 = r3Collider_Translation(c1);
		const R3Vector p2 = r3Collider_Translation(c2);
		const R3Vector middle = Scale(Add(p1, p2), 0.5f);
		contact.point[0] = middle.x;
		contact.point[1] = middle.y;
		contact.point[2] = middle.z;
		R3Vector normal = Normalize(Sub(p2, p1));
		if (Length(normal) < 1.0e-6f)
			normal = V(0, 1, 0);
		contact.normal[0] = normal.x;
		contact.normal[1] = normal.y;
		contact.normal[2] = normal.z;
		contact.speed = 0;
	}

	// The engine body id and sensor flag of a collider, cached on the world (see World::colliderInfo).
	World::ColliderInfo InfoOfCollider(World* world, R3ColliderHandle collider)
	{
		World::ColliderInfo info{NoBody, false};
		if (!Valid(collider))
			return info;
		const uint64_t key = ((uint64_t)collider.index << 32) | collider.generation;
		auto it = world->colliderInfo.find(key);
		if (it != world->colliderInfo.end())
			info = it->second;
		else
		{
			const R3UserData colliderData = r3Collider_UserData(collider);
			if (colliderData.high == SoftColliderTag)
				info.body = (uint32_t)colliderData.low;
			else
			{
				const R3RigidBodyHandle parent = r3Collider_Parent(collider);
				info.body = Valid(parent) ? (uint32_t)r3RigidBody_UserData(parent).low : NoBody;
			}
			info.sensor = r3Collider_IsSensor(collider) != 0;
			if (world->colliderInfo.size() >= 65536)
				world->colliderInfo.clear();
			world->colliderInfo.emplace(key, info);
		}
		if (!world->deformableOwners.empty())
		{
			const uint32_t owner = DeformableOwner(world, collider);
			if (owner != NoBody)
				info.body = owner;
		}
		return info;
	}

	inline uint64_t BodyKey(R3RigidBodyHandle handle) { return ((uint64_t)handle.index << 32) | handle.generation; }

	// Fills world->awakeScratch with the island manager's active bodies (one call instead of one per pair).
	void GatherAwake(World* world)
	{
		std::vector<R3RigidBodyHandle>& active = world->activeBodyScratch;
		size_t capacity = std::max<size_t>(active.capacity(), 64);
		active.resize(capacity);
		size_t count = r3ActiveRigidBodies(world->world, active.data(), capacity);
		while (count > capacity)
		{
			capacity = count + count / 4;
			active.resize(capacity);
			count = r3ActiveRigidBodies(world->world, active.data(), capacity);
		}
		active.resize(count);
		world->awakeScratch.clear();
		for (const R3RigidBodyHandle& handle : active)
			world->awakeScratch.insert(BodyKey(handle));
	}

	// Asleep or static: a pair of these is still touching but has nothing new to report this tick. Soft bodies have
	// no rigid handle here and always count as awake.
	bool Resting(const World* world, const Body& body)
	{
		if (body.motion == 0 && Valid(body.handle))
			return true;
		return Valid(body.handle) && world->awakeScratch.count(BodyKey(body.handle)) == 0;
	}

	void EmitContact(const World* world, R3ColliderHandle c1, R3ColliderHandle c2, uint32_t a, uint32_t b,
		const Body* bodyA, const Body* bodyB, int32_t kind, bool sensor, std::vector<TnRapierContact>& into)
	{
		TnRapierContact contact;
		std::memset(&contact, 0, sizeof(contact));
		contact.bodyA = a;
		contact.bodyB = b;
		contact.objectA = bodyA->userData;
		contact.objectB = bodyB->userData;
		contact.kind = kind;
		contact.sensor = sensor ? 1 : 0;
		FillContactGeometry(world, c1, c2, contact, sensor);
		into.push_back(contact);
	}

	void EmitStoredContact(const ActivePair& pair, int32_t kind, std::vector<TnRapierContact>& into)
	{
		TnRapierContact contact;
		std::memset(&contact, 0, sizeof(contact));
		contact.bodyA = pair.bodyA;
		contact.bodyB = pair.bodyB;
		contact.objectA = pair.objectA;
		contact.objectB = pair.objectB;
		contact.kind = kind;
		contact.sensor = pair.sensor ? 1 : 0;
		into.push_back(contact);
	}

	// ---- hit conversion ----

	uint32_t SubshapeOf(const Body* body, int32_t part, uint32_t feature)
	{
		(void)body;
		return ((uint32_t)std::max(part, 0) & 0xffffu) | (feature << 16);
	}

	// Finds the collider's part index within its body.
	int32_t PartIndex(const Body* body, R3ColliderHandle collider)
	{
		for (size_t i = 0; i < body->colliders.size(); i++)
		{
			if (Same(body->colliders[i], collider))
				return (int32_t)i;
		}
		return 0;
	}

	void ConvertHit(World* world, R3ColliderHandle collider, float fraction, R3Vector point, R3Vector normal,
		float penetration, uint32_t feature, TnRapierHit* out)
	{
		const uint32_t bodyId = BodyIdOfCollider(world, collider);
		if (bodyId == NoBody)
			return;
		const Body* body = world->FindCollision(bodyId);
		const int32_t part = body != nullptr ? PartIndex(body, collider) : 0;
		const bool trimesh = body != nullptr && part < (int32_t)body->parts.size() && body->parts[part].trimesh;
		const int32_t triangle = (trimesh && feature != UINT32_MAX) ? (int32_t)feature : -1;
		out->body = bodyId;
		out->subshape = SubshapeOf(body, part, trimesh ? feature : 0);
		out->fraction = fraction;
		Out(out->point, point);
		Out(out->normal, normal);
		out->penetrationDepth = penetration;
		world->RememberHit(bodyId, out->subshape, point, normal, body != nullptr && body->parts.size() > 1 ? part : -1,
			triangle);
	}

	float PenetrationOf(const R3ShapeCastHit& hit, R3Pose pose)
	{
		const R3Vector witness2 = Add(pose.translation, QRot(pose.rotation, hit.witness2));
		return std::max(0.0f, Dot(Sub(hit.witness1, witness2), hit.normal1));
	}

	bool RayFeatureTriangle(const Body* body, int32_t part, const R3RayHit& hit, uint32_t& feature)
	{
		if (body == nullptr || part < 0 || part >= (int32_t)body->parts.size() || !body->parts[part].trimesh)
		{
			feature = 0;
			return false;
		}
		feature = hit.feature_id;
		return true;
	}
}

// =====================================================================================================================
// Provider
// =====================================================================================================================

int32_t tn_rapier_available(void)
{
	const R3Status status = r3CheckAbi(R3_ABI_VERSION, R3_DIMENSION, sizeof(R3Real), sizeof(R3Vector), sizeof(R3Pose),
		R3_ABI_FEATURES);
	return status == R3_OK ? 1 : 0;
}

const char* tn_rapier_version(void)
{
	return tn_rapier_available() ? r3Version() : "";
}

const char* tn_rapier_build(void)
{
	static std::string description;
	if (!tn_rapier_available())
		return "Rapier3D (not linked)";
	if (description.empty())
	{
		const R3BuildFeatures features = r3BuildFeatures();
		char text[160];
		char threads[16];
		if (!EnvironmentSet("RAYON_NUM_THREADS", threads, sizeof(threads)))
			std::snprintf(threads, sizeof(threads), "4");
		char parallel[48];
		std::snprintf(parallel, sizeof(parallel), "on (%s threads)", threads);
		std::snprintf(text, sizeof(text), "Rapier %s; SIMD %u; parallel %s; enhanced determinism %s",
			r3Version(), (unsigned)features.simd_lanes, features.parallel ? parallel : "off",
			features.enhanced_determinism ? "on" : "off");
		description = text;
	}
	return description.c_str();
}

// =====================================================================================================================
// World
// =====================================================================================================================

namespace
{
	// A parallel Rapier build steps on rayon's global pool, shared by every world. Rayon sizes it from
	// RAYON_NUM_THREADS when it first starts (otherwise one thread per core, and the step gets slower past about eight
	// on a busy scene). Default it to four, like Jolt's three workers plus the stepping thread, leaving cores for the
	// rest of the engine; a value already in the environment wins. Results are bit-identical at any thread count.
	void DefaultRapierThreads()
	{
		static bool done = false;
		if (done)
			return;
		done = true;
		char threads[16];
		if (!r3BuildFeatures().parallel || EnvironmentSet("RAYON_NUM_THREADS", threads, sizeof(threads)))
			return;
#if defined(_WIN32)
		_putenv_s("RAYON_NUM_THREADS", "4");
#else
		setenv("RAYON_NUM_THREADS", "4", 0);
#endif
	}
}

void* tn_rapier_world_new(void)
{
	if (tn_rapier_available() == 0)
		return nullptr;
	DefaultRapierThreads();
	World* world = new World();
	world->world = r3NewWorld();
	if (world->world == nullptr)
	{
		delete world;
		return nullptr;
	}
	return world;
}

void tn_rapier_world_free(void* raw)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr)
		return;
	for (auto& pair : world->characters)
	{
		Character* character = pair.second;
		if (character->controller != nullptr)
			r3FreeKinematicCharacterController(character->controller);
		if (character->shape != nullptr)
			r3FreeSharedShape(character->shape);
		delete character;
	}
	for (auto& pair : world->joints)
		delete pair.second;
	for (auto& pair : world->vehicles)
	{
		if (pair.second->controller != nullptr)
			r3FreeDynamicRayCastVehicleController(pair.second->controller);
		delete pair.second;
	}
	for (auto& pair : world->softBodies)
	{
		if (Valid(pair.second->handle))
			r3RemoveSoftBody(pair.second->handle);
		delete pair.second;
	}
	for (auto& pair : world->ropeTies)
	{
		if (Valid(pair.second->joint))
			r3RemoveImpulseJoint(pair.second->joint, 0);
		if (pair.second->hasAnchor && Valid(pair.second->anchor))
			r3RemoveRigidBody(pair.second->anchor, 1);
		delete pair.second;
	}
	if (world->events != nullptr)
		r3FreeEventCollector(world->events);
	if (world->world != nullptr)
		r3FreeWorld(world->world);
	delete world;
}

void tn_rapier_set_gravity(void* raw, float x, float y, float z)
{
	World* world = static_cast<World*>(raw);
	if (world != nullptr && world->world != nullptr)
		r3SetGravity(world->world, V(x, y, z));
}

void tn_rapier_set_length_scale(void* raw, float scale)
{
	World* world = static_cast<World*>(raw);
	if (world != nullptr && world->world != nullptr && scale > 0.0f)
		r3SetLengthUnit(world->world, scale);
}

void tn_rapier_set_contact_events(void* raw, int32_t enabled)
{
	World* world = static_cast<World*>(raw);
	if (world != nullptr)
		world->contactEvents = enabled != 0;
}

void tn_rapier_set_query_worlds(void* raw, uint32_t groups)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr)
		return;
	world->queryWorlds = groups;
	if (world->queryDirty && world->world != nullptr && !world->queryFull)
	{
		// Only bodies were moved, teleported or created since the last step: push their poses to their colliders and
		// refit just those colliders' query-tree boxes (r3RefreshQueriesForBodies, Tallow's addition to Rapier's C
		// bindings; Rapier itself is stock). No collision detection runs and Rapier's change flags stay for the next
		// step, so the simulation is the same as if no query had happened.
		r3RefreshQueriesForBodies(world->world, world->queryMoved.data(), world->queryMoved.size());
		world->queryMoved.clear();
		world->queryDirty = false;
	}
	else if (world->queryDirty && world->world != nullptr)
	{
		// A structural change (clear, enable/disable, soft bodies, ropes, a restored snapshot): the stock refresh,
		// collision detection without running the solver with an artificial timestep (a tiny solver step can turn
		// resting attachment errors into violent impulses when a new collider is inserted).
		R3PhysicsHooks hooks{};
		hooks.user_data = world;
		hooks.filter_contact_pair = &FilterPair;
		hooks.filter_intersection_pair = &FilterPair;
		r3DetectCollisions(world->world, &hooks, nullptr);
		// Collision-only refresh consumes Rapier's modified-body list without registering new dynamics
		// with the solver. Requeue awake dynamics for the next real step without waking sleeping ones.
		for (const auto& entry : world->bodies)
		{
			const Body& body = entry.second;
			if (body.motion == 2 && r3RigidBody_IsEnabled(body.handle) && !r3RigidBody_IsSleeping(body.handle))
				r3RigidBody_WakeUp(body.handle, 0);
		}
		world->queryMoved.clear();
		world->queryFull = false;
		world->queryDirty = false;
	}
}

// ---- vehicles ----

void tn_rapier_soft_update_after_step(World* world);

namespace
{
	float WheelRadius(const Vehicle* vehicle)
	{
		for (const TnRapierWheel& wheel : vehicle->wheels)
		{
			if (wheel.radius > 0.0f)
				return wheel.radius;
		}
		return 0.4f;
	}

	int DrivenCount(const Vehicle* vehicle)
	{
		int count = 0;
		for (const TnRapierWheel& wheel : vehicle->wheels)
			count += wheel.driven != 0 ? 1 : 0;
		return count;
	}

	size_t AxisIndex(R3Vector value)
	{
		const float ax = std::fabs(value.x), ay = std::fabs(value.y), az = std::fabs(value.z);
		if (ax >= ay && ax >= az)
			return 0;
		return ay >= az ? 1 : 2;
	}

	void UpdateVehicles(World* world, float deltaTime)
	{
		if (world->vehicles.empty() || deltaTime <= 0.0f)
			return;
		std::vector<R3WheelState> states;
		for (auto& entry : world->vehicles)
		{
			Vehicle* vehicle = entry.second;
			if (vehicle->controller == nullptr || vehicle->wheels.empty())
				continue;
			const size_t wheelCount = vehicle->wheels.size();
			states.resize(wheelCount);
			const size_t read = r3DynamicRayCastVehicleController_Wheels(vehicle->controller, states.data(), wheelCount);
			float drivenSpin = 0.0f;
			for (size_t i = 0; i < read; i++)
			{
				const float spin = states[i].rotation;
				const float previous = vehicle->lastRotation[i];
				float delta = spin - previous;
				vehicle->wheelSpeed[i] = delta / deltaTime;
				vehicle->lastRotation[i] = spin;
				if (vehicle->wheels[i].driven)
					drivenSpin += vehicle->wheelSpeed[i];
			}
			const int driven = DrivenCount(vehicle);
			drivenSpin = driven > 0 ? drivenSpin / (float)driven : 0.0f;

			// A simple automatic gearbox over the declared ratios. Reverse when asked for while rolling back.
			const float speed = r3DynamicRayCastVehicleController_CurrentVehicleSpeed(vehicle->controller);
			const float radius = std::max(WheelRadius(vehicle), 0.05f);
			if (vehicle->inputForward < -0.05f && speed < 0.25f)
			{
				vehicle->gear = -1;
				vehicle->ratio = vehicle->reverseRatio;
			}
			else
			{
				if (vehicle->gear < 1)
					vehicle->gear = 1;
				if (!vehicle->gears.empty())
				{
					vehicle->gear = std::clamp(vehicle->gear, 1, (int32_t)vehicle->gears.size());
					vehicle->ratio = vehicle->gears[(size_t)vehicle->gear - 1];
					const float guess = std::fabs(speed) / radius * vehicle->ratio * 9.5493f;
					if (guess > vehicle->maxRPM * 0.9f && vehicle->gear < (int32_t)vehicle->gears.size())
						vehicle->gear++;
					else if (guess < vehicle->minRPM * 1.25f && vehicle->gear > 1)
						vehicle->gear--;
					vehicle->ratio = vehicle->gears[(size_t)vehicle->gear - 1];
				}
			}
			const float wheelRpm = std::fabs(drivenSpin) * 9.5493f;
			vehicle->rpm = std::clamp(wheelRpm * std::fabs(vehicle->ratio), vehicle->minRPM, vehicle->maxRPM);
			if (vehicle->rpm < vehicle->minRPM)
				vehicle->rpm = vehicle->minRPM;

			float engineForce = 0.0f;
			if (std::fabs(vehicle->inputForward) > 0.01f)
			{
				// The gearbox's final drive; Jolt's differentials use the same 3.5.
				const float finalDrive = 3.5f;
				engineForce = vehicle->maxTorque * std::fabs(vehicle->inputForward) * std::fabs(vehicle->ratio) * finalDrive / radius;
				if (vehicle->inputForward < 0.0f)
					engineForce = -engineForce;
				if (driven > 0)
					engineForce /= (float)driven;
			}
			for (size_t i = 0; i < wheelCount; i++)
			{
				const TnRapierWheel& wheel = vehicle->wheels[i];
				const float steer = wheel.steers ? vehicle->inputRight * wheel.maxSteerRadians : 0.0f;
				vehicle->steer[i] = steer;
				float brake = vehicle->inputBrake * wheel.maxBrakeTorque;
				if (!wheel.steers)
					brake = std::max(brake, vehicle->inputHandBrake * wheel.maxHandBrakeTorque);
				const float force = wheel.driven ? engineForce : 0.0f;
				r3DynamicRayCastVehicleController_SetWheelControls(vehicle->controller, i, steer, force, brake);
			}

			QueryContext context;
			context.world = world;
			context.ignoreBody = vehicle->chassisId;
			context.excludeSensors = true;
			R3QueryOptions options = Options(context);
			const R3Status status = r3DynamicRayCastVehicleController_UpdateVehicle(vehicle->controller, deltaTime, &options);
			(void)status;
		}
	}
}

namespace
{
	inline R3Vector MatPoint(const float* m, R3Vector p);
	inline void MatFromPose(R3Pose pose, float* out);
	inline void MatMul(const float* a, const float* b, float* out);
	void ApplyPendingShellDents(World* world);
}

void HoldFromImpactsShells(World* world)
{
	for (auto& entry : world->softBodies)
	{
		SoftBody* soft = entry.second;
		if (soft->kind != 2 || soft->impacts == 0 || !Valid(soft->handle) || !soft->hasObject || Valid(soft->deformable))
			continue;
		for (size_t i = 0; i < soft->dents.size(); i++)
		{
			const R3Vector at = MatPoint(soft->lastObject, Add(soft->restLocal[i], soft->dents[i]));
			r3SoftBody_SetParticlePosition(soft->handle, i, at);
		}
	}
}

void tn_rapier_step(void* raw, float deltaTime, int32_t* errorMask, float* stepMilliseconds)
{
	if (errorMask != nullptr)
		*errorMask = 0;
	if (stepMilliseconds != nullptr)
		*stepMilliseconds = 0;
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr)
		return;
	if (deltaTime > 0.0f)
		r3SetTimeStep(world->world, deltaTime);
	UpdateVehicles(world, deltaTime);
	if (world->events == nullptr)
		world->events = r3NewEventCollector();
	R3PhysicsHooks hooks;
	std::memset(&hooks, 0, sizeof(hooks));
	hooks.user_data = world;
	hooks.filter_contact_pair = &FilterPair;
	hooks.filter_intersection_pair = &FilterPair;
	// The velocity history only feeds shell impact dents, so it is kept only while a shell exists. Static bodies
	// never move and keep zero history.
	bool shells = false;
	for (const auto& entry : world->softBodies)
		shells |= entry.second->kind == 2;
	if (shells)
	{
		for (auto& entry : world->bodies)
		{
			Body& body = entry.second;
			if (body.motion != 0 && Valid(body.handle))
			{
				body.prevPrevPrevLinear = body.prevPrevLinear;
				body.prevPrevLinear = body.prevLinear;
				body.prevLinear = r3RigidBody_Linvel(body.handle);
				body.prevAngular = r3RigidBody_Angvel(body.handle);
			}
		}
	}
	ApplyPendingShellDents(world);
	// Events accumulate in the collector until cleared; only this step's tear events are wanted afterwards.
	r3EventCollector_Clear(world->events);
	const auto stepStart = std::chrono::steady_clock::now();
	const R3Status status = r3Step(world->world, &hooks, world->events);
	if (stepMilliseconds != nullptr)
		*stepMilliseconds = std::chrono::duration<float, std::milli>(std::chrono::steady_clock::now() - stepStart).count();
	// Tallow's force APIs act for one step. Rapier's force and torque accumulators are persistent.
	for (const uint32_t id : world->forcedBodies)
	{
		Body* body = world->Find(id);
		if (body == nullptr)
			continue;
		if (body->hasStepForce && Valid(body->handle))
			r3RigidBody_ResetForces(body->handle, 0);
		if (body->hasStepTorque && Valid(body->handle))
			r3RigidBody_ResetTorques(body->handle, 0);
		body->hasStepForce = false;
		body->hasStepTorque = false;
	}
	world->forcedBodies.clear();
	world->queryDirty = false;
	world->queryFull = false;
	world->queryMoved.clear();
	tn_rapier_soft_update_after_step(world);
	HoldFromImpactsShells(world);
	if (status != R3_OK)
	{
		if (errorMask != nullptr)
			*errorMask |= 1;
	}
}

void tn_rapier_clear(void* raw)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr)
		return;
	for (auto& pair : world->characters)
	{
		Character* character = pair.second;
		if (Valid(character->body))
			r3RemoveRigidBody(character->body, 1);
		if (character->controller != nullptr)
			r3FreeKinematicCharacterController(character->controller);
		if (character->shape != nullptr)
			r3FreeSharedShape(character->shape);
		delete character;
	}
	world->characters.clear();
	for (auto& pair : world->joints)
	{
		if (Valid(pair.second->handle))
			r3RemoveImpulseJoint(pair.second->handle, 0);
		delete pair.second;
	}
	world->joints.clear();
	for (auto& pair : world->vehicles)
	{
		if (pair.second->controller != nullptr)
			r3FreeDynamicRayCastVehicleController(pair.second->controller);
		delete pair.second;
	}
	world->vehicles.clear();
	for (auto& pair : world->softBodies)
	{
		if (Valid(pair.second->handle))
			r3RemoveSoftBody(pair.second->handle);
		delete pair.second;
	}
	world->softBodies.clear();
	for (auto& pair : world->ropeTies)
	{
		if (Valid(pair.second->joint))
			r3RemoveImpulseJoint(pair.second->joint, 0);
		if (pair.second->hasAnchor && Valid(pair.second->anchor))
			r3RemoveRigidBody(pair.second->anchor, 1);
		delete pair.second;
	}
	world->ropeTies.clear();
	world->deformableOwners.clear();
	for (auto& entry : world->bodies)
	{
		if (Valid(entry.second.handle))
			r3RemoveRigidBody(entry.second.handle, 1);
	}
	world->bodies.clear();
	world->activePairList.clear();
	world->contacts.clear();
	world->recentHits.clear();
	world->recentHitNext = 0;
	world->colliderInfo.clear();
	world->MarkQueryFull();
	world->nextId = 1;
}

int32_t tn_rapier_contacts(void* raw, TnRapierContact* out, int32_t capacity)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr)
		return 0;
	world->contacts.clear();
	if (!world->contactEvents)
	{
		world->activePairList.clear();
		return 0;
	}

	// The narrow phase's pairs are the truth: a pair may have begun during the broad-phase refresh before the step,
	// which a collision-event listener would not have seen. Solid pairs come from one r3ActiveContactSummaries call
	// (Tallow's addition to Rapier's C bindings; Rapier itself is stock): only pairs with an active solver contact
	// (the narrow phase also holds pairs whose bounding boxes merely overlap), with ids, sensor flags, resting state
	// and the strongest contact's point, normal and speed worked out in one read-only pass, skipped for resting
	// pairs that have nothing to report. Asking per pair cost four locked calls into Rapier per event.
	std::vector<R3ContactSummary>& summaries = world->contactSummaryScratch;
	{
		// Buffer protocol: a too-small buffer gets the required count back and no elements, so grow and retry.
		size_t capacity = std::max<size_t>(summaries.capacity(), 64);
		summaries.resize(capacity);
		size_t count = r3ActiveContactSummaries(world->world, 1, summaries.data(), capacity);
		while (count > capacity)
		{
			capacity = count + count / 4;
			summaries.resize(capacity);
			count = r3ActiveContactSummaries(world->world, 1, summaries.data(), capacity);
		}
		summaries.resize(count);
	}
	std::vector<R3IntersectionPair>& intersectionPairs = world->intersectionPairScratch;
	{
		size_t capacity = std::max<size_t>(intersectionPairs.capacity(), 32);
		intersectionPairs.resize(capacity);
		size_t count = r3IntersectionPairs(world->world, intersectionPairs.data(), capacity);
		while (count > capacity)
		{
			capacity = count + count / 4;
			intersectionPairs.resize(capacity);
			count = r3IntersectionPairs(world->world, intersectionPairs.data(), capacity);
		}
		intersectionPairs.resize(count);
	}

	// This tick's touching pairs, sorted by exact key (duplicates dropped): a merge against last tick's sorted list
	// finds begins, stays and ends with no hashing or per-pair allocation. Events come out in key order, which is
	// deterministic.
	auto& current = world->currentPairScratch;
	current.clear();
	for (const R3ContactSummary& summary : summaries)
	{
		if (Valid(summary.collider1) && Valid(summary.collider2))
			current.push_back({MakeExactPair(summary.collider1, summary.collider2), summary.collider1, summary.collider2,
				&summary});
	}
	bool anyIntersection = false;
	for (const R3IntersectionPair& pair : intersectionPairs)
	{
		if (pair.intersecting && Valid(pair.collider1) && Valid(pair.collider2))
		{
			current.push_back({MakeExactPair(pair.collider1, pair.collider2), pair.collider1, pair.collider2, nullptr});
			anyIntersection = true;
		}
	}
	std::sort(current.begin(), current.end());
	current.erase(std::unique(current.begin(), current.end(),
		[](const World::CurrentPair& x, const World::CurrentPair& y) { return x.key == y.key; }), current.end());
	// Sensor pairs still check resting per body, from one active-body list.
	if (anyIntersection)
		GatherAwake(world);

	// The engine body id a summary names for one side: a shell's owner, a soft body's id, else the parent's id.
	auto summaryBody = [world](R3ColliderHandle collider, R3UserData colliderData, R3UserData bodyData) -> uint32_t
	{
		if (!world->deformableOwners.empty())
		{
			const uint32_t owner = DeformableOwner(world, collider);
			if (owner != NoBody)
				return owner;
		}
		if (colliderData.high == SoftColliderTag)
			return (uint32_t)colliderData.low;
		return bodyData.low != 0 || bodyData.high != 0 ? (uint32_t)bodyData.low : NoBody;
	};

	std::vector<ActivePair>& now = world->nowPairScratch;
	now.clear();
	now.reserve(current.size());
	const std::vector<ActivePair>& before = world->activePairList;
	size_t cursor = 0;
	for (const World::CurrentPair& pair : current)
	{
		// Last tick's pairs sorting before this one are gone: they ended.
		while (cursor < before.size() && before[cursor].key < pair.key)
		{
			// The collider may have gone with its body; the stored ids still name the pair that ended.
			EmitStoredContact(before[cursor], 1, world->contacts);
			cursor++;
		}
		const bool touching = cursor < before.size() && before[cursor].key == pair.key;
		if (touching)
			cursor++;
		const int32_t kind = touching ? 2 : 0;
		uint32_t idA, idB;
		bool sensor, resting;
		if (pair.summary != nullptr)
		{
			const R3ContactSummary& summary = *pair.summary;
			idA = summaryBody(pair.a, summary.collider_user_data1, summary.body_user_data1);
			idB = summaryBody(pair.b, summary.collider_user_data2, summary.body_user_data2);
			sensor = summary.sensor1 != 0 || summary.sensor2 != 0;
			resting = summary.resting != 0;
		}
		else
		{
			const World::ColliderInfo infoA = InfoOfCollider(world, pair.a);
			const World::ColliderInfo infoB = InfoOfCollider(world, pair.b);
			idA = infoA.body;
			idB = infoB.body;
			sensor = infoA.sensor || infoB.sensor;
			resting = false;
		}
		const Body* bodyA = world->FindCollision(idA);
		const Body* bodyB = world->FindCollision(idB);
		if (pair.summary == nullptr && bodyA != nullptr && bodyB != nullptr)
			resting = Resting(world, *bodyA) && Resting(world, *bodyB);
		// Like Jolt, a pair that went to sleep together (or against something static) stays entered without a stay
		// every tick; it reports again once either side wakes.
		const bool quiet = kind == 2 && resting;
		if (!quiet && idA != NoBody && idB != NoBody && idA != idB && bodyA != nullptr && bodyB != nullptr)
		{
			if (pair.summary != nullptr && pair.summary->has_point != 0)
			{
				const R3ContactSummary& summary = *pair.summary;
				TnRapierContact contact;
				std::memset(&contact, 0, sizeof(contact));
				contact.bodyA = idA;
				contact.bodyB = idB;
				contact.objectA = bodyA->userData;
				contact.objectB = bodyB->userData;
				contact.kind = kind;
				contact.sensor = sensor ? 1 : 0;
				Out(contact.point, summary.point);
				Out(contact.normal, summary.normal);
				contact.speed = summary.normal_speed;
				world->contacts.push_back(contact);
			}
			else
			{
				// Sensors, and a resting pair that only now begins (its geometry was skipped): ask for it.
				EmitContact(world, pair.a, pair.b, idA, idB, bodyA, bodyB, kind, sensor, world->contacts);
			}
		}
		ActivePair stored;
		stored.key = pair.key;
		stored.a = pair.a;
		stored.b = pair.b;
		stored.bodyA = idA;
		stored.bodyB = idB;
		stored.objectA = bodyA != nullptr ? bodyA->userData : 0;
		stored.objectB = bodyB != nullptr ? bodyB->userData : 0;
		stored.sensor = sensor;
		now.push_back(stored);
	}
	for (; cursor < before.size(); cursor++)
		EmitStoredContact(before[cursor], 1, world->contacts);
	// `now` was filled in key order, so it stays sorted for the next tick's merge.
	world->activePairList.swap(now);

	const int32_t count = (int32_t)world->contacts.size();
	if (out != nullptr && capacity > 0)
	{
		const int32_t copy = std::min(count, capacity);
		std::memcpy(out, world->contacts.data(), sizeof(TnRapierContact) * (size_t)copy);
	}
	return count;
}

int32_t tn_rapier_contacts_copy(void* raw, TnRapierContact* out, int32_t capacity)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr)
		return 0;
	const int32_t count = (int32_t)world->contacts.size();
	if (out != nullptr && capacity > 0)
		std::memcpy(out, world->contacts.data(), sizeof(TnRapierContact) * (size_t)std::min(count, capacity));
	return count;
}

// =====================================================================================================================
// Bodies
// =====================================================================================================================

uint32_t tn_rapier_body_create(void* raw, int32_t motion, const float position[3], const float rotation[4],
	const TnRapierPart* parts, int32_t partCount, uint32_t objectCode, uint32_t group, int32_t motionClass,
	uint32_t collisionMemberships, uint32_t collisionFilter, int32_t sensor, int32_t debris, float friction,
	float restitution, float linearDamping, float angularDamping, float gravityScale, int32_t allowSleeping,
	int32_t continuousCollision, int32_t freezeRotation, int32_t overrideMass, float mass, uint64_t userData,
	uint32_t wantedId)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || parts == nullptr || partCount <= 0)
		return NoBody;

	const uint32_t id = AllocateId(world, wantedId);

	R3RigidBodyDesc body = motion == 2 ? r3DynamicRigidBodyDesc() :
		(motion == 1 ? r3KinematicPositionBasedRigidBodyDesc() : r3FixedRigidBodyDesc());
	body.position = Pose(position, rotation);
	body.linvel = V(0, 0, 0);
	body.angvel = R3AngVector{0, 0, 0};
	body.gravityScale = gravityScale;
	body.linearDamping = std::max(linearDamping, 0.0f);
	body.angularDamping = std::max(angularDamping, 0.0f);
	body.canSleep = allowSleeping ? 1 : 0;
	body.sleeping = 0;
	body.ccdEnabled = continuousCollision ? 1 : 0;
	if (freezeRotation)
		body.lockedAxes = 0x38; // rotations X, Y, Z (translations are the low three bits)
	body.enabled = 1;
	body.userData = R3UserData{id, 0};

	const R3RigidBodyHandle handle = r3InsertRigidBody(world->world, &body);
	if (!Valid(handle))
		return NoBody;

	Body entry;
	entry.handle = handle;
	entry.motion = motion;
	entry.motionClass = motionClass;
	entry.objectCode = objectCode;
	entry.group = group;
	entry.memberships = collisionMemberships;
	entry.filter = collisionFilter;
	entry.debris = debris != 0;
	entry.sensor = sensor != 0;
	entry.userData = userData;

	const float perPartMass = (motion == 2 && overrideMass) ? std::max(mass, 0.001f) / (float)partCount : 0.0f;
	for (int32_t i = 0; i < partCount; i++)
	{
		R3ColliderDesc collider = MakeCollider(parts[i], entry, sensor != 0, friction, restitution, perPartMass,
			motion == 2 && overrideMass);
		const R3ColliderHandle colliderHandle = r3InsertCollider(handle, &collider);
		if (!Valid(colliderHandle))
			continue;
		entry.colliders.push_back(colliderHandle);
		PartInfo info;
		info.kind = parts[i].kind;
		info.trimesh = parts[i].kind == TN_RAPIER_TRIMESH;
		entry.parts.push_back(info);
	}
	if (entry.colliders.empty())
	{
		r3RemoveRigidBody(handle, 1);
		return NoBody;
	}
	world->bodies[id] = entry;
	world->MarkQueryMoved(entry.handle);
	if (id >= world->nextId)
		world->nextId = id + 1;
	return id;
}

void tn_rapier_body_destroy(void* raw, uint32_t id)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr)
		return;
	auto soft = world->softBodies.find(id);
	if (soft != world->softBodies.end())
	{
		tn_rapier_soft_destroy(raw, id);
		return;
	}
	auto it = world->bodies.find(id);
	if (it == world->bodies.end())
		return;
	if (Valid(it->second.shellSurface))
	{
		for (const auto& entry : world->softBodies)
			if (entry.second->ignoredBody == id)
				tn_rapier_soft_ignore(raw, entry.first, NoBody);
	}
	if (Valid(it->second.handle))
		r3RemoveRigidBody(it->second.handle, 1);
	world->bodies.erase(it);
	// Queries skip removed colliders and read collision groups live: nothing to refresh.
	for (auto joint = world->joints.begin(); joint != world->joints.end();)
	{
		const Joint* j = joint->second;
		if (j->bodyA == id || j->bodyB == id)
		{
			if (Valid(j->handle))
				r3RemoveImpulseJoint(j->handle, 0);
			delete j;
			joint = world->joints.erase(joint);
		}
		else
			++joint;
	}
}

void tn_rapier_body_pose(void* raw, uint32_t id, float position[3], float rotation[4])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body == nullptr || !Valid(body->handle))
		return;
	const R3Pose pose = r3RigidBody_Position(body->handle);
	Out(position, pose.translation);
	rotation[0] = pose.rotation.x;
	rotation[1] = pose.rotation.y;
	rotation[2] = pose.rotation.z;
	rotation[3] = pose.rotation.w;
}

void tn_rapier_body_set_pose(void* raw, uint32_t id, const float position[3], const float rotation[4], int32_t wake)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
	{
		r3RigidBody_SetPosition(body->handle, Pose(position, rotation), wake ? 1 : 0);
		world->MarkQueryMoved(body->handle);
	}
}

void tn_rapier_body_move_kinematic(void* raw, uint32_t id, const float position[3], const float rotation[4],
	float deltaTime)
{
	(void)deltaTime;
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body == nullptr || !Valid(body->handle))
		return;
	if (body->motion == 1)
	{
		r3RigidBody_SetNextKinematicTranslation(body->handle, V(position));
		r3RigidBody_SetNextKinematicRotation(body->handle, Q(rotation));
	}
	else
	{
		r3RigidBody_SetPosition(body->handle, Pose(position, rotation), 1);
		world->MarkQueryMoved(body->handle);
	}
}

void tn_rapier_body_linvel(void* raw, uint32_t id, float velocity[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		Out(velocity, r3RigidBody_Linvel(body->handle));
	else
		velocity[0] = velocity[1] = velocity[2] = 0;
}

void tn_rapier_body_set_linvel(void* raw, uint32_t id, const float velocity[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_SetLinvel(body->handle, V(velocity), 1);
}

void tn_rapier_body_angvel(void* raw, uint32_t id, float velocity[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		Out(velocity, r3RigidBody_Angvel(body->handle));
	else
		velocity[0] = velocity[1] = velocity[2] = 0;
}

void tn_rapier_body_set_angvel(void* raw, uint32_t id, const float velocity[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_SetAngvel(body->handle, R3AngVector{velocity[0], velocity[1], velocity[2]}, 1);
}

void tn_rapier_body_set_velocities(void* raw, uint32_t id, const float linear[3], const float angular[3])
{
	tn_rapier_body_set_linvel(raw, id, linear);
	tn_rapier_body_set_angvel(raw, id, angular);
	tn_rapier_body_activate(raw, id);
}

void tn_rapier_body_add_force(void* raw, uint32_t id, const float force[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle) && r3RigidBody_AddForce(body->handle, V(force), 1) == R3_OK)
		world->MarkStepForce(id, *body, true, false);
}

void tn_rapier_body_add_force_at(void* raw, uint32_t id, const float force[3], const float point[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle) && r3RigidBody_AddForceAtPoint(body->handle, V(force), V(point), 1) == R3_OK)
		world->MarkStepForce(id, *body, true, true);
}

void tn_rapier_body_add_torque(void* raw, uint32_t id, const float torque[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle) &&
		r3RigidBody_AddTorque(body->handle, R3AngVector{torque[0], torque[1], torque[2]}, 1) == R3_OK)
		world->MarkStepForce(id, *body, false, true);
}

void tn_rapier_body_add_impulse(void* raw, uint32_t id, const float impulse[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_ApplyImpulse(body->handle, V(impulse), 1);
}

void tn_rapier_body_point_velocity(void* raw, uint32_t id, const float point[3], float velocity[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		Out(velocity, r3RigidBody_VelocityAtPoint(body->handle, V(point)));
	else
		velocity[0] = velocity[1] = velocity[2] = 0;
}

void tn_rapier_body_set_sleeping(void* raw, uint32_t id, int32_t sleeping)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body == nullptr || !Valid(body->handle))
		return;
	if (sleeping)
		r3RigidBody_Sleep(body->handle);
	else
		r3RigidBody_WakeUp(body->handle, 1);
}

int32_t tn_rapier_body_is_sleeping(void* raw, uint32_t id)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr)
		return 0;
	auto soft = world->softBodies.find(id);
	if (soft != world->softBodies.end())
		return Valid(soft->second->handle) && r3SoftBody_IsSleeping(soft->second->handle) ? 1 : 0;
	Body* body = world->Find(id);
	return body != nullptr && Valid(body->handle) && r3RigidBody_IsSleeping(body->handle) ? 1 : 0;
}

void tn_rapier_body_activate(void* raw, uint32_t id)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_WakeUp(body->handle, 1);
}

float tn_rapier_body_mass(void* raw, uint32_t id)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	return body != nullptr && Valid(body->handle) ? r3RigidBody_Mass(body->handle) : 0.0f;
}

uint32_t tn_rapier_body_object_code(void* raw, uint32_t id)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	return body != nullptr ? body->objectCode : 0;
}

void tn_rapier_body_set_object_code(void* raw, uint32_t id, uint32_t objectCode, uint32_t group,
	int32_t motionClass, uint32_t collisionMemberships, uint32_t collisionFilter)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body == nullptr)
		return;
	body->objectCode = objectCode;
	body->group = group;
	body->motionClass = motionClass;
	body->memberships = collisionMemberships;
	body->filter = collisionFilter;
	// Queries skip removed colliders and read collision groups live: nothing to refresh.
	UpdateFilterHooks(*body);
	const R3InteractionGroups groups{collisionMemberships, collisionFilter, 0};
	for (R3ColliderHandle collider : body->colliders)
		r3Collider_SetCollisionGroups(collider, groups);
	if (Valid(body->shellSurface))
	{
		r3Collider_SetCollisionGroups(body->shellSurface, groups);
		r3Collider_SetSolverGroups(body->shellSurface, groups);
	}
}

void tn_rapier_body_set_enabled(void* raw, uint32_t id, int32_t enabled)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
	{
		r3RigidBody_SetEnabled(body->handle, enabled ? 1 : 0);
		if (Valid(body->shellSurface))
			r3Collider_SetEnabled(body->shellSurface, enabled ? 1 : 0);
		world->MarkQueryFull();
	}
}

int32_t tn_rapier_body_buoyancy(void* raw, uint32_t id, const float surfacePoint[3],
	const float surfaceNormal[3], float buoyancy, float linearDrag, float angularDrag,
	const float fluidVelocity[3], float deltaTime)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body == nullptr || !Valid(body->handle) || deltaTime <= 0.0f)
		return 0;
	const R3Pose pose = r3RigidBody_Position(body->handle);
	const R3Vector level = V(surfacePoint);
	const R3Vector normal = Normalize(V(surfaceNormal));
	if (Length(normal) < 1.0e-6f)
		return 0;
	// How much of the body's box is below the surface, along the surface normal.
	float under = 1.0f;
	if (!body->colliders.empty())
	{
		const R3Aabb bounds = r3Collider_ComputeAabb(body->colliders[0]);
		const R3Vector centre = Scale(Add(bounds.mins, bounds.maxs), 0.5f);
		const R3Vector half = Scale(Sub(bounds.maxs, bounds.mins), 0.5f);
		const float reach = std::fabs(normal.x) * half.x + std::fabs(normal.y) * half.y +
			std::fabs(normal.z) * half.z;
		const float depth = Dot(Sub(level, centre), normal);
		under = reach > 0.0001f ? std::clamp((reach + depth) / (reach * 2.0f), 0.0f, 1.0f) : 1.0f;
	}
	if (under <= 0.0f)
		return 0;
	const float mass = std::max(r3RigidBody_Mass(body->handle), 0.001f);
	R3Vector gravity = r3Gravity(world->world);
	const R3Vector force = Scale(gravity, -mass * std::max(buoyancy, 0.0f) * under);
	if (r3RigidBody_AddForceAtPoint(body->handle, force, pose.translation, 1) == R3_OK)
		world->MarkStepForce(id, *body, true, true);
	R3Vector velocity = r3RigidBody_Linvel(body->handle);
	const R3Vector flow = V(fluidVelocity);
	velocity = Add(flow, Scale(Sub(velocity, flow), std::exp(-std::max(linearDrag, 0.0f) * under * deltaTime)));
	r3RigidBody_SetLinvel(body->handle, velocity, 1);
	R3Vector spin = r3RigidBody_Angvel(body->handle);
	spin = Scale(spin, std::exp(-std::max(angularDrag, 0.0f) * under * deltaTime));
	r3RigidBody_SetAngvel(body->handle, spin, 1);
	return 1;
}

// =====================================================================================================================
// Queries
// =====================================================================================================================

int32_t tn_rapier_raycast(void* raw, const float origin[3], const float direction[3], float maxDistance,
	uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hit)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || hit == nullptr || maxDistance <= 0.0f)
		return 0;
	QueryContext context;
	context.world = world;
	context.layerMask = layerMask;
	context.ignoreBody = ignoreBody;
	R3QueryOptions options = Options(context);
	const R3Vector from = V(origin);
	const R3Vector dir = V(direction);
	const R3RayHit result = r3CastRay(world->world, &options, from, dir, maxDistance, 1);
	if (!Valid(result.collider))
		return 0;
	const R3Vector point = Add(from, Scale(dir, result.time_of_impact));
	uint32_t feature = 0;
	const uint32_t bodyId = BodyIdOfCollider(world, result.collider);
	const Body* body = world->FindCollision(bodyId);
	const int32_t part = body != nullptr ? PartIndex(body, result.collider) : 0;
	RayFeatureTriangle(body, part, result, feature);
	ConvertHit(world, result.collider, maxDistance > 0.0f ? result.time_of_impact / maxDistance : 0.0f, point,
		result.normal, 0.0f, feature, hit);
	return 1;
}

int32_t tn_rapier_raycast_all(void* raw, const float origin[3], const float direction[3], float maxDistance,
	uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hits, int32_t capacity)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || hits == nullptr || capacity <= 0 || maxDistance <= 0.0f)
		return 0;
	QueryContext context;
	context.world = world;
	context.layerMask = layerMask;
	context.ignoreBody = ignoreBody;
	std::vector<R3ColliderHandle> excluded;
	context.excluded = &excluded;
	const R3Vector from = V(origin);
	const R3Vector dir = V(direction);
	std::unordered_set<uint32_t> emitted;
	int32_t written = 0;
	float travelled = 0.0f;
	const float epsilon = std::max(1.0e-4f, maxDistance * 1.0e-5f);
	for (int attempt = 0; attempt < 512 && written < capacity; attempt++)
	{
		const float remaining = maxDistance - travelled;
		if (remaining <= 0.0f)
			break;
		R3QueryOptions options = Options(context);
		const R3RayHit result = r3CastRay(world->world, &options, Add(from, Scale(dir, travelled)), dir, remaining, 1);
		if (!Valid(result.collider))
			break;
		const float distance = travelled + result.time_of_impact;
		const uint32_t bodyId = BodyIdOfCollider(world, result.collider);
		if (bodyId == NoBody)
			break;
		if (emitted.insert(bodyId).second)
		{
			const Body* body = world->FindCollision(bodyId);
			const int32_t part = body != nullptr ? PartIndex(body, result.collider) : 0;
			uint32_t feature = 0;
			RayFeatureTriangle(body, part, result, feature);
			const R3Vector point = Add(from, Scale(dir, distance));
			ConvertHit(world, result.collider, distance / maxDistance, point, result.normal, 0.0f, feature,
				&hits[written]);
			written++;
		}
		excluded.push_back(result.collider);
		travelled = distance + epsilon;
	}
	return written;
}

int32_t tn_rapier_shape_cast(void* raw, const TnRapierPart* part, const float origin[3],
	const float rotation[4], const float displacement[3], uint32_t layerMask, uint32_t ignoreBody,
	TnRapierHit* hit)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || part == nullptr || hit == nullptr)
		return 0;
	R3SharedShape* shape = BuildShape(*part);
	if (shape == nullptr)
		return 0;
	QueryContext context;
	context.world = world;
	context.layerMask = layerMask;
	context.ignoreBody = ignoreBody;
	R3QueryOptions options = Options(context);
	R3ShapeCastOptions castOptions = r3DefaultShapeCastOptions();
	castOptions.max_time_of_impact = 1.0f;
	castOptions.target_distance = 0.0f;
	castOptions.stop_at_penetration = 1;
	castOptions.compute_impact_geometry_on_penetration = 1;
	const R3Pose pose = {V(origin), Q(rotation)};
	const R3ShapeCastHit result = r3CastShape(world->world, &options, pose, V(displacement), shape, castOptions);
	r3FreeSharedShape(shape);
	if (!Valid(result.collider))
		return 0;
	ConvertHit(world, result.collider, result.time_of_impact, result.witness1, result.normal1,
		PenetrationOf(result, pose), 0, hit);
	return 1;
}

int32_t tn_rapier_shape_cast_all(void* raw, const TnRapierPart* part, const float origin[3],
	const float rotation[4], const float displacement[3], uint32_t layerMask, uint32_t ignoreBody,
	TnRapierHit* hits, int32_t capacity)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || part == nullptr || hits == nullptr || capacity <= 0)
		return 0;
	R3SharedShape* shape = BuildShape(*part);
	if (shape == nullptr)
		return 0;
	QueryContext context;
	context.world = world;
	context.layerMask = layerMask;
	context.ignoreBody = ignoreBody;
	std::vector<R3ColliderHandle> excluded;
	context.excluded = &excluded;
	const R3Pose start = {V(origin), Q(rotation)};
	const R3Vector move = V(displacement);
	R3ShapeCastOptions castOptions = r3DefaultShapeCastOptions();
	castOptions.max_time_of_impact = 1.0f;
	castOptions.target_distance = 0.0f;
	castOptions.stop_at_penetration = 1;
	castOptions.compute_impact_geometry_on_penetration = 1;
	std::unordered_set<uint32_t> emitted;
	int32_t written = 0;
	R3Vector from = start.translation;
	float travelled = 0.0f;
	const float length = Length(move);
	const float epsilon = std::max(1.0e-4f, length * 1.0e-5f);
	for (int attempt = 0; attempt < 512 && written < capacity && length > 1.0e-9f; attempt++)
	{
		R3QueryOptions options = Options(context);
		const R3Pose pose = {from, start.rotation};
		const R3ShapeCastHit result = r3CastShape(world->world, &options, pose, move, shape, castOptions);
		if (!Valid(result.collider))
			break;
		const float distance = travelled + result.time_of_impact * length;
		const uint32_t bodyId = BodyIdOfCollider(world, result.collider);
		if (bodyId == NoBody)
			break;
		if (emitted.insert(bodyId).second)
		{
			ConvertHit(world, result.collider, distance / length, result.witness1, result.normal1,
				PenetrationOf(result, pose), 0, &hits[written]);
			written++;
		}
		excluded.push_back(result.collider);
		travelled = distance + epsilon;
		from = Add(start.translation, Scale(Normalize(move), travelled));
	}
	r3FreeSharedShape(shape);
	return written;
}

int32_t tn_rapier_overlap(void* raw, const TnRapierPart* part, const float origin[3],
	const float rotation[4], uint32_t layerMask, uint32_t ignoreBody, TnRapierHit* hits, int32_t capacity)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || part == nullptr || hits == nullptr || capacity <= 0)
		return 0;
	R3SharedShape* shape = BuildShape(*part);
	if (shape == nullptr)
		return 0;
	const R3Pose pose = {V(origin), Q(rotation)};
	QueryContext context;
	context.world = world;
	context.layerMask = layerMask;
	context.ignoreBody = ignoreBody;
	R3QueryOptions options = Options(context);
	std::vector<R3ColliderHandle> found;
	found.resize(256);
	size_t count = r3IntersectShape(world->world, &options, pose, shape, found.data(), found.size());
	if (count > found.size())
	{
		found.resize(count);
		count = r3IntersectShape(world->world, &options, pose, shape, found.data(), found.size());
	}
	found.resize(std::min(count, found.size()));
	int32_t written = 0;
	for (R3ColliderHandle collider : found)
	{
		if (written >= capacity)
			break;
		const uint32_t bodyId = BodyIdOfCollider(world, collider);
		const Body* body = world->FindCollision(bodyId);
		if (body == nullptr)
			continue;
		const int32_t partIndex = PartIndex(body, collider);
		// Ask the moving shape and this collider for the contact geometry at zero velocity.
		QueryContext only;
		only.world = world;
		only.layerMask = 0xffffffffu;
		only.onlyBody = bodyId;
		R3QueryOptions onlyOptions = Options(only);
		R3ShapeCastOptions castOptions = r3DefaultShapeCastOptions();
		castOptions.max_time_of_impact = 0.0f;
		castOptions.target_distance = 0.0f;
		castOptions.stop_at_penetration = 1;
		castOptions.compute_impact_geometry_on_penetration = 1;
		R3Vector point = r3Collider_Translation(collider);
		R3Vector normal = Normalize(Sub(V(origin), point));
		float penetration = 0.0f;
		bool resolved = false;
		if (Length(normal) > 1.0e-6f)
		{
			const R3ShapeCastHit probe = r3CastShape(world->world, &onlyOptions, pose, V(0, 0, 0), shape, castOptions);
			if (Valid(probe.collider) && Same(probe.collider, collider))
			{
				point = probe.witness1;
				normal = probe.normal1;
				penetration = PenetrationOf(probe, pose);
				resolved = true;
			}
		}
		if (!resolved && Length(normal) < 1.0e-6f)
			normal = V(0, 1, 0);
		TnRapierHit hit;
		std::memset(&hit, 0, sizeof(hit));
		ConvertHit(world, collider, 0.0f, point, normal, penetration, 0, &hit);
		hit.subshape = SubshapeOf(body, partIndex, 0);
		hits[written++] = hit;
	}
	r3FreeSharedShape(shape);
	return written;
}

int32_t tn_rapier_check(void* raw, const TnRapierPart* part, const float origin[3], const float rotation[4],
	uint32_t layerMask, uint32_t ignoreBody)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || part == nullptr)
		return 0;
	R3SharedShape* shape = BuildShape(*part);
	if (shape == nullptr)
		return 0;
	QueryContext context;
	context.world = world;
	context.layerMask = layerMask;
	context.ignoreBody = ignoreBody;
	R3QueryOptions options = Options(context);
	R3ColliderHandle one;
	const size_t count = r3IntersectShape(world->world, &options, R3Pose{V(origin), Q(rotation)}, shape, &one, 1);
	r3FreeSharedShape(shape);
	return count > 0 ? 1 : 0;
}

int32_t tn_rapier_hit_detail(void* raw, uint32_t body, uint32_t subshape, const float point[3],
	float normal[3], int32_t* part, int32_t* triangle)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr)
		return 0;
	const R3Vector at = V(point);
	const HitRecord* best = nullptr;
	float bestDistance = 1.0e30f;
	// Newest first: the slot before recentHitNext, walking back around the ring.
	const size_t hitCount = world->recentHits.size();
	for (size_t k = 0; k < hitCount; k++)
	{
		const HitRecord* it = &world->recentHits[(world->recentHitNext + 256 * 2 - 1 - k) % 256 % hitCount];
		if (it->body != body || it->subshape != subshape)
			continue;
		const float distance = Dot(Sub(it->point, at), Sub(it->point, at));
		if (distance < bestDistance)
		{
			bestDistance = distance;
			best = it;
			if (distance <= 1.0e-8f)
				break;
		}
	}
	if (best == nullptr)
		return 0;
	Out(normal, best->normal);
	if (part != nullptr)
		*part = best->part;
	if (triangle != nullptr)
		*triangle = best->triangle;
	return 1;
}

// =====================================================================================================================
// Joints
// =====================================================================================================================

namespace
{
	R3Pose LocalPose(const R3Pose& body, R3Vector worldPoint, R3Rotation worldRotation)
	{
		const R3Rotation inverse = QConj(body.rotation);
		R3Pose pose;
		pose.translation = QRot(inverse, Sub(worldPoint, body.translation));
		pose.rotation = QNorm(QMul(inverse, worldRotation));
		return pose;
	}
}

void* tn_rapier_joint_create(void* raw, int32_t kind, uint32_t bodyA, uint32_t bodyB, const float anchor[3],
	const float axis[3], const float childAnchor[3], const float childAxis[3], const float childNormal[3],
	float swingLimitRadians, float travel)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr)
		return nullptr;
	Body* a = world->Find(bodyA);
	Body* b = world->Find(bodyB);
	if (a == nullptr || b == nullptr || !Valid(a->handle) || !Valid(b->handle))
		return nullptr;
	const R3Pose poseA = r3RigidBody_Position(a->handle);
	const R3Pose poseB = r3RigidBody_Position(b->handle);
	R3Vector worldAxis = Normalize(V(axis));
	if (Length(worldAxis) < 1.0e-6f)
		worldAxis = V(0, 1, 0);
	R3JointDesc desc = r3DefaultJointDesc();
	desc.contactsEnabled = 0;
	Joint* joint = new Joint();
	joint->kind = kind;
	joint->bodyA = bodyA;
	joint->bodyB = bodyB;
	joint->worldAxis = worldAxis;

	switch (kind)
	{
	case 0: // ball / spherical
	{
		desc.lockedAxes = 0x07; // translations locked
		const R3Vector world = V(anchor);
		joint->frame1 = LocalPose(poseA, world, R3Rotation{0, 0, 0, 1});
		joint->frame2 = LocalPose(poseB, world, R3Rotation{0, 0, 0, 1});
		desc.localFrame1 = joint->frame1;
		desc.localFrame2 = joint->frame2;
		if (swingLimitRadians > 0.0001f)
		{
			// A cone around the joint frame's X axis: limit the two swing rotations.
			r3JointDesc_SetLimits(&desc, 4, -swingLimitRadians, swingLimitRadians);
			r3JointDesc_SetLimits(&desc, 5, -swingLimitRadians, swingLimitRadians);
			desc.limitAxes |= (uint8_t)(1 << 4) | (uint8_t)(1 << 5);
		}
		break;
	}
	case 1: // hinge / revolute about the world axis
	{
		const R3Rotation frameRotation = AlignX(worldAxis);
		const R3Vector world = V(anchor);
		joint->frame1 = LocalPose(poseA, world, frameRotation);
		joint->frame2 = LocalPose(poseB, world, frameRotation);
		desc.lockedAxes = 0x37; // translations and rotations Y, Z locked; rotation X free
		desc.localFrame1 = joint->frame1;
		desc.localFrame2 = joint->frame2;
		break;
	}
	case 2: // slider / prismatic along the world axis
	{
		const R3Rotation frameRotation = AlignX(worldAxis);
		// The engine's slider anchors are body A and body B points; the axis is the travel direction.
		joint->frame1 = LocalPose(poseA, V(anchor), frameRotation);
		joint->frame2 = LocalPose(poseB, V(childAnchor), frameRotation);
		desc.lockedAxes = 0x3e; // translation Y, Z and every rotation locked; translation X free
		desc.localFrame1 = joint->frame1;
		desc.localFrame2 = joint->frame2;
		const float limit = std::max(travel, 0.001f);
		r3JointDesc_SetLimits(&desc, 0, -limit, limit);
		desc.limitAxes |= 1;
		break;
	}
	default:
		delete joint;
		return nullptr;
	}
	if (kind != 0)
	{
		// The child frame's roll around the hinge/slider axis decides which way body B starts. Rapier derives that
		// from the local frames above; the engine's child axes are only used to build them, and the frames already
		// align both bodies about the world axis.
		(void)childAnchor;
		(void)childAxis;
		(void)childNormal;
	}
	const R3ImpulseJointHandle handle = r3InsertImpulseJoint(a->handle, b->handle, &desc);
	if (!Valid(handle))
	{
		delete joint;
		return nullptr;
	}
	joint->handle = handle;
	world->joints[(uint32_t)(uintptr_t)joint] = joint;
	return joint;
}

void tn_rapier_joint_destroy(void* raw, void* jointRaw)
{
	World* world = static_cast<World*>(raw);
	Joint* joint = static_cast<Joint*>(jointRaw);
	if (world == nullptr || joint == nullptr)
		return;
	if (Valid(joint->handle))
		r3RemoveImpulseJoint(joint->handle, 0);
	world->joints.erase((uint32_t)(uintptr_t)joint);
	delete joint;
}

void tn_rapier_slider_spring(void* raw, void* jointRaw, float stiffness, float damping)
{
	(void)raw;
	Joint* joint = static_cast<Joint*>(jointRaw);
	if (joint == nullptr || joint->kind != 2 || !Valid(joint->handle))
		return;
	// A position motor at 0 on the sliding axis is the suspension spring.
	r3ImpulseJoint_SetMotor(joint->handle, 0, 0.0f, 0.0f, std::max(stiffness, 0.0f), std::max(damping, 0.0f), 1);
	r3ImpulseJoint_SetMotorMaxForce(joint->handle, 0, 1.0e9f, 1);
}

float tn_rapier_slider_position(void* raw, void* jointRaw)
{
	World* world = static_cast<World*>(raw);
	Joint* joint = static_cast<Joint*>(jointRaw);
	if (world == nullptr || joint == nullptr || joint->kind != 2)
		return 0.0f;
	Body* a = world->Find(joint->bodyA);
	Body* b = world->Find(joint->bodyB);
	if (a == nullptr || b == nullptr)
		return 0.0f;
	const R3Pose poseA = r3RigidBody_Position(a->handle);
	const R3Pose poseB = r3RigidBody_Position(b->handle);
	const R3Vector axis = QRot(poseA.rotation, QRot(joint->frame1.rotation, V(1, 0, 0)));
	const R3Vector pointA = Add(poseA.translation, QRot(poseA.rotation, joint->frame1.translation));
	const R3Vector pointB = Add(poseB.translation, QRot(poseB.rotation, joint->frame2.translation));
	return Dot(Sub(pointB, pointA), axis);
}

void tn_rapier_hinge_motor(void* raw, void* jointRaw, float speed, float torque, float angle, int32_t mode,
	float response, float maximumSpeed)
{
	(void)raw;
	Joint* joint = static_cast<Joint*>(jointRaw);
	if (joint == nullptr || joint->kind != 1 || !Valid(joint->handle))
		return;
	const uint32_t axis = 3; // rotation about the frame's X
	if (mode == 0)
	{
		r3ImpulseJoint_SetMotor(joint->handle, axis, 0.0f, 0.0f, 0.0f, 0.0f, 1);
		r3ImpulseJoint_SetMotorMaxForce(joint->handle, axis, 0.0f, 1);
		return;
	}
	if (mode == 1)
	{
		r3ImpulseJoint_SetMotor(joint->handle, axis, 0.0f, speed, 0.0f, 1.0f, 1);
	}
	else
	{
		// Turn towards an angle, no faster than maximumSpeed; response makes it push harder.
		const float stiffness = std::max(response, 0.1f) * 50.0f;
		const float damping = std::max(response, 0.1f) * 5.0f;
		const float targetVelocity = std::clamp(angle * std::max(response, 0.1f), -maximumSpeed, maximumSpeed);
		r3ImpulseJoint_SetMotor(joint->handle, axis, angle, targetVelocity, stiffness, damping, 1);
	}
	r3ImpulseJoint_SetMotorMaxForce(joint->handle, axis, std::max(torque, 0.0f), 1);
}

float tn_rapier_hinge_angle(void* raw, void* jointRaw)
{
	World* world = static_cast<World*>(raw);
	Joint* joint = static_cast<Joint*>(jointRaw);
	if (world == nullptr || joint == nullptr || joint->kind != 1)
		return 0.0f;
	Body* a = world->Find(joint->bodyA);
	Body* b = world->Find(joint->bodyB);
	if (a == nullptr || b == nullptr)
		return 0.0f;
	const R3Pose poseA = r3RigidBody_Position(a->handle);
	const R3Pose poseB = r3RigidBody_Position(b->handle);
	const R3Rotation rotA = QMul(poseA.rotation, joint->frame1.rotation);
	const R3Rotation rotB = QMul(poseB.rotation, joint->frame2.rotation);
	const R3Vector axis = QRot(rotA, V(1, 0, 0));
	const R3Vector refA = QRot(rotA, V(0, 1, 0));
	const R3Vector refB = QRot(rotB, V(0, 1, 0));
	return std::atan2(Dot(Cross(refA, refB), axis), Dot(refA, refB));
}

// =====================================================================================================================
// Character controller
// =====================================================================================================================

namespace
{
	R3SharedShape* BuildCharacterShape(const TnRapierPart* parts, int32_t partCount, std::vector<PartInfo>& infos)
	{
		infos.clear();
		if (partCount != 1)
			return nullptr; // characters are one convex shape
		return BuildShape(parts[0]);
	}
}

void* tn_rapier_character_create(void* raw, const TnRapierPart* parts, int32_t partCount,
	const float position[3], const float rotation[4], float maxSlopeRadians, float mass, float pushStrength,
	float supportHeight, uint32_t objectCode, uint32_t group, uint32_t collisionMemberships,
	uint32_t collisionFilter, uint64_t userData, int32_t innerBody)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr)
		return nullptr;
	Character* character = new Character();
	character->shape = BuildCharacterShape(parts, partCount, character->parts);
	if (character->shape == nullptr)
	{
		delete character;
		return nullptr;
	}
	character->objectCode = objectCode;
	character->group = group;
	character->memberships = collisionMemberships;
	character->filter = collisionFilter;
	character->userData = userData;
	character->maxSlope = maxSlopeRadians;
	character->mass = std::max(mass, 0.001f);
	character->pushStrength = std::max(pushStrength, 0.0f);
	character->supportHeight = supportHeight;
	character->position = V(position);
	character->rotation = Q(rotation);
	character->shapeCenter = V(parts[0].position);

	const uint32_t id = AllocateId(world, NoBody);
	character->bodyId = id;

	R3RigidBodyDesc body = r3KinematicPositionBasedRigidBodyDesc();
	body.position = Pose(position, rotation);
	body.userData = R3UserData{id, 0};
	character->body = r3InsertRigidBody(world->world, &body);
	if (!Valid(character->body))
	{
		r3FreeSharedShape(character->shape);
		delete character;
		return nullptr;
	}
	Body bodyInfo;
	bodyInfo.motion = 1;
	bodyInfo.motionClass = 1;
	bodyInfo.objectCode = objectCode;
	bodyInfo.group = group;
	bodyInfo.memberships = collisionMemberships;
	bodyInfo.filter = collisionFilter;
	bodyInfo.userData = userData;
	R3ColliderDesc collider = MakeCollider(parts[0], bodyInfo, false, 0.4f, 0.0f, 0.0f, false);
	collider.massMode = R3_MASS_TOTAL;
	collider.mass = character->mass;
	character->collider = r3InsertCollider(character->body, &collider);
	if (!Valid(character->collider))
	{
		r3RemoveRigidBody(character->body, 1);
		r3FreeSharedShape(character->shape);
		delete character;
		return nullptr;
	}
	(void)innerBody;
	// Queries see the new character before the next step (its collider may reuse a destroyed collider's slot).
	world->MarkQueryMoved(character->body);

	character->controller = r3NewKinematicCharacterController();
	if (character->controller == nullptr)
	{
		r3RemoveRigidBody(character->body, 1);
		r3FreeSharedShape(character->shape);
		delete character;
		return nullptr;
	}
	r3KinematicCharacterController_SetUp(character->controller, V(0, 1, 0));
	r3KinematicCharacterController_SetOffset(character->controller, R3CharacterLength{CharacterContactOffset, 0});
	r3KinematicCharacterController_SetSlide(character->controller, 1);
	r3KinematicCharacterController_SetSlopes(character->controller, character->maxSlope,
		std::max(character->maxSlope, 0.7f));
	r3KinematicCharacterController_SetSnapToGround(character->controller, 1, R3CharacterLength{0.2f, 0});
	r3KinematicCharacterController_SetAutostep(character->controller, 1, R3CharacterLength{0.3f, 0},
		R3CharacterLength{0.1f, 0}, 1);

	world->characters[(uint32_t)(uintptr_t)character] = character;
	return character;
}

void tn_rapier_character_destroy(void* raw, void* characterRaw)
{
	World* world = static_cast<World*>(raw);
	Character* character = static_cast<Character*>(characterRaw);
	if (world == nullptr || character == nullptr)
		return;
	if (Valid(character->body))
		r3RemoveRigidBody(character->body, 1);
	if (character->controller != nullptr)
		r3FreeKinematicCharacterController(character->controller);
	if (character->shape != nullptr)
		r3FreeSharedShape(character->shape);
	world->characters.erase((uint32_t)(uintptr_t)character);
	delete character;
}

uint32_t tn_rapier_character_inner_body(void* raw, void* characterRaw)
{
	(void)raw;
	Character* character = static_cast<Character*>(characterRaw);
	return character != nullptr ? character->bodyId : NoBody;
}

namespace
{
	void CharacterStateOf(World* world, Character* character, TnRapierCharacterState* state)
	{
		if (state == nullptr)
			return;
		std::memset(state, 0, sizeof(*state));
		Out(state->position, character->position);
		Out(state->velocity, character->velocity);
		state->groundState = 3;
		state->groundBody = NoBody;
		state->groundNormal[1] = 1;
	}
}

void tn_rapier_character_state(void* raw, void* characterRaw, TnRapierCharacterState* state)
{
	World* world = static_cast<World*>(raw);
	Character* character = static_cast<Character*>(characterRaw);
	if (world == nullptr || character == nullptr)
		return;
	CharacterStateOf(world, character, state);
}

void tn_rapier_character_move(void* raw, void* characterRaw, uint32_t collisionMemberships,
	uint32_t collisionFilter, const float velocity[3], float deltaTime, float stepHeight, float stepDown,
	float stepReach, TnRapierCharacterState* state)
{
	World* world = static_cast<World*>(raw);
	Character* character = static_cast<Character*>(characterRaw);
	if (world == nullptr || world->world == nullptr || character == nullptr || deltaTime <= 0.0f)
		return;
	character->memberships = collisionMemberships;
	character->filter = collisionFilter;

	QueryContext context;
	context.world = world;
	context.layerMask = 0xffffffffu;
	context.ignoreBody = character->bodyId;
	context.memberships = collisionMemberships;
	context.filter = collisionFilter;
	context.groupFilter = true;
	context.excludeSoftBodies = true;
	// A trigger reports what passes through; it must not stop a character.
	context.excludeSensors = true;
	R3QueryOptions options = Options(context);

	r3KinematicCharacterController_SetAutostep(character->controller, stepHeight > 0.0001f ? 1 : 0,
		R3CharacterLength{std::max(stepHeight, 0.0f), 0}, R3CharacterLength{std::max(stepReach * 0.5f, 0.02f), 0}, 1);
	r3KinematicCharacterController_SetSnapToGround(character->controller, stepDown > 0.0001f ? 1 : 0,
		R3CharacterLength{std::max(stepDown, 0.0f), 0});
	r3KinematicCharacterController_SetSlopes(character->controller, character->maxSlope,
		std::max(character->maxSlope, 0.7f));

	const R3Vector centre = Add(character->position, QRot(character->rotation, character->shapeCenter));
	const R3Pose pose = {centre, character->rotation};
	const R3Vector desired = V(velocity);
	const R3Vector translation = Scale(desired, deltaTime);
	// Fast falls need room for the sweep's contact recovery. Keep the nudge near Rapier's
	// default when walking so successive contacts cannot build up as a visible rise.
	const float downward = std::max(-translation.y, 0.0f);
	r3KinematicCharacterController_SetNormalNudgeFactor(character->controller,
		std::clamp(downward * 0.015f, 0.0001f, 0.001f));
	const R3CharacterMovement movement = r3KinematicCharacterController_MoveShape(world->world, &options,
		character->controller, deltaTime, character->shape, pose, translation);

	character->lastHits.clear();
	character->velocity = Scale(movement.translation, 1.0f / deltaTime);
	// Sweep corrections move the shape over steps and slopes. Only the requested upward
	// velocity should carry into the next tick as a jump.
	character->velocity.y = std::min(character->velocity.y, std::max(desired.y, 0.0f));
	character->position = Add(character->position, movement.translation);

	R3CharacterCollision localCollisions[32];
	R3CharacterCollision* collisions = localCollisions;
	const size_t localCapacity = sizeof(localCollisions) / sizeof(localCollisions[0]);
	size_t count = r3KinematicCharacterController_Collisions(character->controller, collisions, localCapacity);
	std::vector<R3CharacterCollision> extraCollisions;
	if (count > localCapacity)
	{
		extraCollisions.resize(count);
		collisions = extraCollisions.data();
		count = std::min(r3KinematicCharacterController_Collisions(character->controller, collisions,
			extraCollisions.size()), extraCollisions.size());
	}
	R3Vector groundNormal = V(0, 1, 0);
	uint32_t groundBody = NoBody;
	float groundDot = -2.0f;
	for (size_t i = 0; i < count; i++)
	{
		if (!Valid(collisions[i].collider))
			continue;
		const uint32_t bodyId = BodyIdOfCollider(world, collisions[i].collider);
		const R3Vector point = collisions[i].hit.witness1;
		const R3Vector normal = collisions[i].hit.normal1;
		TnRapierCharacterHit hit;
		std::memset(&hit, 0, sizeof(hit));
		hit.body = bodyId;
		const Body* other = world->Find(bodyId);
		hit.userData = other != nullptr ? other->userData : 0;
		Out(hit.point, point);
		Out(hit.normal, normal);
		character->lastHits.push_back(hit);
		if (normal.y > groundDot)
		{
			groundDot = normal.y;
			groundNormal = normal;
			groundBody = bodyId;
		}
	}

	CharacterStateOf(world, character, state);
	if (state != nullptr)
	{
		const float walkable = std::cos(character->maxSlope) - 0.02f;
		bool grounded = movement.grounded != 0;
		// A wall from the sweep is not a floor. Check for support at the final position when
		// Rapier's sweep sees only a wall or when the contact offset kept it above the floor.
		const bool smallVerticalMove = std::fabs(movement.translation.y) < CharacterContactOffset;
		if (desired.y <= 0.0f && (!grounded || groundDot < walkable || smallVerticalMove))
		{
			R3ShapeCastOptions supportOptions = r3DefaultShapeCastOptions();
			supportOptions.max_time_of_impact = CharacterContactOffset * 2.2f;
			supportOptions.target_distance = 0.0f;
			supportOptions.stop_at_penetration = 1;
			supportOptions.compute_impact_geometry_on_penetration = 1;
			const R3Pose finalPose{Add(centre, movement.translation), character->rotation};
			const R3ShapeCastHit support = r3CastShape(world->world, &options, finalPose, V(0, -1, 0),
				character->shape, supportOptions);
			if (Valid(support.collider) && support.normal1.y > 0.0f)
			{
				grounded = true;
				groundNormal = support.normal1;
				groundDot = support.normal1.y;
				groundBody = BodyIdOfCollider(world, support.collider);
				const float correction = CharacterContactOffset - support.time_of_impact;
				if (smallVerticalMove && groundDot > 0.999f && std::fabs(correction) <= CharacterContactOffset * 0.6f)
				{
					// Keep the contact offset on a flat floor and report support velocity instead
					// of feeding the sweep's small separation nudge back as a jump.
					character->position.y += correction;
					const Body* floor = world->Find(groundBody);
					character->velocity.y = floor != nullptr ?
						r3RigidBody_VelocityAtPoint(floor->handle, character->position).y : 0.0f;
					Out(state->position, character->position);
					Out(state->velocity, character->velocity);
				}
			}
		}
		const bool steep = groundDot > 0.01f && groundDot < walkable &&
			(grounded || movement.is_sliding_down_slope != 0);
		if (groundDot <= 0.01f)
		{
			groundNormal = V(0, 1, 0);
			groundBody = NoBody;
		}
		Out(state->groundNormal, groundNormal);
		if (grounded || steep)
		{
			state->groundState = steep ? 1 : 0;
			state->groundBody = groundBody;
			const Body* ground = world->Find(groundBody);
			if (ground != nullptr && Valid(ground->handle))
			{
				const R3Vector at = Add(character->position, V(0, -character->supportHeight, 0));
				Out(state->groundVelocity, r3RigidBody_VelocityAtPoint(ground->handle, at));
			}
		}
		else if (count > 0)
			state->groundState = 2;
	}

	r3RigidBody_SetNextKinematicTranslation(character->body, character->position);
	if (character->pushStrength > 0.0f && count > 0)
	{
		r3KinematicCharacterController_SolveCharacterCollisionImpulses(character->controller, character->shape,
			deltaTime, character->mass * std::max(character->pushStrength, 1.0f) / 100.0f, &options);
	}
}

void tn_rapier_character_set_state(void* raw, void* characterRaw, uint32_t collisionMemberships,
	uint32_t collisionFilter, const float position[3], const float rotation[4], const float velocity[3])
{
	World* world = static_cast<World*>(raw);
	Character* character = static_cast<Character*>(characterRaw);
	if (world == nullptr || character == nullptr)
		return;
	(void)collisionMemberships;
	(void)collisionFilter;
	character->position = V(position);
	character->rotation = Q(rotation);
	character->velocity = V(velocity);
	r3RigidBody_SetPosition(character->body, R3Pose{character->position, character->rotation}, 1);
	r3RigidBody_SetNextKinematicTranslation(character->body, character->position);
	// Other queries this tick see the character where it was put.
	world->MarkQueryMoved(character->body);
	character->lastHits.clear();
}

int32_t tn_rapier_character_set_shape(void* raw, void* characterRaw, const TnRapierPart* parts,
	int32_t partCount, uint32_t collisionMemberships, uint32_t collisionFilter, float maxPenetration)
{
	World* world = static_cast<World*>(raw);
	Character* character = static_cast<Character*>(characterRaw);
	if (world == nullptr || world->world == nullptr || character == nullptr || parts == nullptr || partCount != 1)
		return 0;
	R3SharedShape* shape = BuildShape(parts[0]);
	if (shape == nullptr)
		return 0;

	QueryContext context;
	context.world = world;
	context.layerMask = 0xffffffffu;
	context.ignoreBody = character->bodyId;
	context.memberships = collisionMemberships;
	context.filter = collisionFilter;
	context.groupFilter = true;
	context.excludeSoftBodies = true;
	R3QueryOptions options = Options(context);
	R3ColliderHandle one;
	const R3Vector centre = Add(character->position, QRot(character->rotation, V(parts[0].position)));
	const size_t hits = r3IntersectShape(world->world, &options, R3Pose{centre, character->rotation}, shape, &one, 1);
	if (hits > 0 && maxPenetration <= 0.001f)
	{
		r3FreeSharedShape(shape);
		return 0;
	}

	const R3Status status = r3Collider_SetShape(character->collider, shape);
	if (status != R3_OK)
	{
		r3FreeSharedShape(shape);
		return 0;
	}
	r3FreeSharedShape(character->shape);
	character->shape = shape;
	character->shapeCenter = V(parts[0].position);
	character->memberships = collisionMemberships;
	character->filter = collisionFilter;
	return 1;
}

int32_t tn_rapier_character_hits(void* raw, void* characterRaw, TnRapierCharacterHit* hits, int32_t capacity)
{
	(void)raw;
	Character* character = static_cast<Character*>(characterRaw);
	if (character == nullptr || hits == nullptr || capacity <= 0)
		return 0;
	const int32_t count = std::min((int32_t)character->lastHits.size(), capacity);
	for (int32_t i = 0; i < count; i++)
		hits[i] = character->lastHits[i];
	return count;
}

// =====================================================================================================================
// Soft bodies
// =====================================================================================================================

namespace
{
	inline void MatIdentity(float* m)
	{
		for (int i = 0; i < 16; i++)
			m[i] = 0.0f;
		m[0] = m[5] = m[10] = m[15] = 1.0f;
	}

	// Column-major 4x4: out = a * b.
	inline void MatMul(const float* a, const float* b, float* out)
	{
		float r[16];
		for (int col = 0; col < 4; col++)
		{
			for (int row = 0; row < 4; row++)
			{
				r[col * 4 + row] = a[row] * b[col * 4] + a[4 + row] * b[col * 4 + 1] +
					a[8 + row] * b[col * 4 + 2] + a[12 + row] * b[col * 4 + 3];
			}
		}
		for (int i = 0; i < 16; i++)
			out[i] = r[i];
	}

	inline R3Vector MatPoint(const float* m, R3Vector p)
	{
		return V(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
			m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
			m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]);
	}

	inline R3Vector MatDirection(const float* m, R3Vector p)
	{
		return V(m[0] * p.x + m[4] * p.y + m[8] * p.z,
			m[1] * p.x + m[5] * p.y + m[9] * p.z,
			m[2] * p.x + m[6] * p.y + m[10] * p.z);
	}

	inline void MatFromPose(R3Pose pose, float* out)
	{
		const R3Rotation q = pose.rotation;
		const float xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z;
		const float xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z;
		const float wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z;
		out[0] = 1 - 2 * (yy + zz);
		out[1] = 2 * (xy + wz);
		out[2] = 2 * (xz - wy);
		out[3] = 0;
		out[4] = 2 * (xy - wz);
		out[5] = 1 - 2 * (xx + zz);
		out[6] = 2 * (yz + wx);
		out[7] = 0;
		out[8] = 2 * (xz + wy);
		out[9] = 2 * (yz - wx);
		out[10] = 1 - 2 * (xx + yy);
		out[11] = 0;
		out[12] = pose.translation.x;
		out[13] = pose.translation.y;
		out[14] = pose.translation.z;
		out[15] = 1;
	}

	R3Rotation MatRotation(const float* m)
	{
		const R3Vector x = Normalize(V(m[0], m[1], m[2]));
		const R3Vector z = Normalize(Cross(x, V(m[4], m[5], m[6])));
		const R3Vector y = Cross(z, x);
		const float trace = x.x + y.y + z.z;
		if (trace > 0.0f)
		{
			const float w = 0.5f * std::sqrt(1.0f + trace);
			return R3Rotation{(y.z - z.y) / (4.0f * w), (z.x - x.z) / (4.0f * w), (x.y - y.x) / (4.0f * w), w};
		}
		if (x.x >= y.y && x.x >= z.z)
		{
			const float q = 0.5f * std::sqrt(1.0f + x.x - y.y - z.z);
			return R3Rotation{q, (x.y + y.x) / (4.0f * q), (x.z + z.x) / (4.0f * q), (y.z - z.y) / (4.0f * q)};
		}
		if (y.y > z.z)
		{
			const float q = 0.5f * std::sqrt(1.0f + y.y - x.x - z.z);
			return R3Rotation{(x.y + y.x) / (4.0f * q), q, (y.z + z.y) / (4.0f * q), (z.x - x.z) / (4.0f * q)};
		}
		const float q = 0.5f * std::sqrt(1.0f + z.z - x.x - y.y);
		return R3Rotation{(x.z + z.x) / (4.0f * q), (y.z + z.y) / (4.0f * q), q, (x.y - y.x) / (4.0f * q)};
	}

	// Affine inverse (the object's local-to-world transform has a linear part and a translation).
	bool MatInvert(const float* m, float* out)
	{
		const R3Vector c0 = V(m[0], m[1], m[2]);
		const R3Vector c1 = V(m[4], m[5], m[6]);
		const R3Vector c2 = V(m[8], m[9], m[10]);
		const R3Vector cross12 = Cross(c1, c2);
		const float det = Dot(c0, cross12);
		if (std::fabs(det) < 1.0e-12f)
		{
			MatIdentity(out);
			return false;
		}
		const float inv = 1.0f / det;
		const R3Vector r0 = Scale(cross12, inv);
		const R3Vector r1 = Scale(Cross(c2, c0), inv);
		const R3Vector r2 = Scale(Cross(c0, c1), inv);
		// The cross products give rows of the inverse; the matrix is stored column-major.
		out[0] = r0.x; out[1] = r1.x; out[2] = r2.x; out[3] = 0;
		out[4] = r0.y; out[5] = r1.y; out[6] = r2.y; out[7] = 0;
		out[8] = r0.z; out[9] = r1.z; out[10] = r2.z; out[11] = 0;
		const R3Vector t = V(m[12], m[13], m[14]);
		const R3Vector it = Scale(V(Dot(r0, t), Dot(r1, t), Dot(r2, t)), -1.0f);
		out[12] = it.x; out[13] = it.y; out[14] = it.z; out[15] = 1;
		return true;
	}

	uint64_t SoftEdgeKey(uint32_t a, uint32_t b)
	{
		return ((uint64_t)std::min(a, b) << 32) | std::max(a, b);
	}

	// Regular authored grids can use Rapier's cloth recipe, including both shear diagonals
	// and the second-neighbor bend constraints. Preserve the authored triangles for rendering.
	bool SetClothGrid(R3SoftBodyDesc& desc, const std::vector<R3Vector>& positions, const uint32_t* triangles,
		size_t triangleCount)
	{
		const R3Vector origin = positions[0];
		const R3Vector dv = Sub(positions[1], origin);
		const float tolerance = std::max(Length(dv) * 0.001f, 1.0e-5f);
		size_t cols = 2;
		while (cols < positions.size() && Length(Sub(positions[cols], Add(origin, Scale(dv, (float)cols)))) < tolerance)
			cols++;
		if (cols == positions.size() || positions.size() % cols != 0)
			return false;
		const size_t rows = positions.size() / cols;
		const R3Vector du = Sub(positions[cols], origin);
		const size_t quads = (rows - 1) * (cols - 1);
		if (Length(Cross(du, dv)) < tolerance * tolerance || triangleCount != quads * 2)
			return false;

		for (size_t i = 0; i < positions.size(); i++)
		{
			const R3Vector expected = Add(origin, Add(Scale(du, (float)(i / cols)), Scale(dv, (float)(i % cols))));
			if (Length(Sub(positions[i], expected)) > tolerance)
				return false;
		}

		std::vector<uint8_t> corners(quads, 0);
		for (size_t t = 0; t < triangleCount; t++)
		{
			const uint32_t* face = triangles + t * 3;
			const size_t row = std::min({face[0] / cols, face[1] / cols, face[2] / cols});
			const size_t col = std::min({face[0] % cols, face[1] % cols, face[2] % cols});
			if (row >= rows - 1 || col >= cols - 1)
				return false;
			uint8_t mask = 0;
			for (int j = 0; j < 3; j++)
			{
				const size_t dr = face[j] / cols - row, dc = face[j] % cols - col;
				if (dr > 1 || dc > 1)
					return false;
				mask |= (uint8_t)(1u << (dr * 2 + dc));
			}
			if (mask != 7 && mask != 11 && mask != 13 && mask != 14)
				return false;
			uint8_t& previous = corners[row * (cols - 1) + col];
			const uint8_t different = previous ^ mask;
			if (previous != 0 && different != 6 && different != 9)
				return false;
			previous |= mask;
		}

		desc.kind = R3_SOFT_DESC_CLOTH_ANISOTROPIC;
		desc.a = origin;
		desc.du = du;
		desc.dv = dv;
		desc.nx = rows;
		desc.ny = cols;
		return true;
	}

	// Fill surfaces visible from their center with tetrahedra sharing one interior particle.
	// The collision mesh, painted pins and render vertices keep their original particle indices.
	bool BuildJellyCells(const std::vector<R3Vector>& positions, R3Vector center,
		const uint32_t* triangles, int32_t triangleCount, std::vector<R3Tetrahedron>& cells, float& volume)
	{
		struct EdgeUse { int count = 0; int winding = 0; };
		std::unordered_map<uint64_t, EdgeUse> edgeUses;
		const uint32_t interior = (uint32_t)positions.size();
		cells.reserve((size_t)triangleCount);
		float signedVolume = 0.0f;
		int orientation = 0;
		bool fillsInterior = true;
		for (int32_t t = 0; t < triangleCount; t++)
		{
			const uint32_t* face = triangles + t * 3;
			const uint32_t a = face[0], b = face[1], c = face[2];
			const float sixVolume = Dot(Sub(positions[a], center),
				Cross(Sub(positions[b], center), Sub(positions[c], center)));
			signedVolume += sixVolume / 6.0f;
			const int sign = sixVolume > 0.0f ? 1 : -1;
			if (orientation == 0)
				orientation = sign;
			fillsInterior &= std::fabs(sixVolume) > 6.0f * std::numeric_limits<float>::epsilon() && sign == orientation;
			cells.push_back(sign > 0 ? R3Tetrahedron{a, b, c, interior} : R3Tetrahedron{a, c, b, interior});
			for (int edge = 0; edge < 3; edge++)
			{
				const uint32_t from = face[edge], to = face[(edge + 1) % 3];
				auto& use = edgeUses[SoftEdgeKey(from, to)];
				use.count++;
				use.winding += from < to ? 1 : -1;
			}
		}
		for (const auto& edge : edgeUses)
		{
			if (edge.second.count != 2 || edge.second.winding != 0)
			{
				volume = 0.0f;
				return false;
			}
		}
		volume = std::fabs(signedVolume);
		return fillsInterior;
	}
}

uint32_t tn_rapier_soft_create(void* raw, const float* positions, int32_t vertexCount, const uint32_t* triangles,
	int32_t triangleCount, const float* pinned, const float* stiffness, const float center[3],
	const float objectMatrix[16], float totalMass, const TnRapierSoftSettings* settings, uint64_t userData)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || positions == nullptr || vertexCount < 3 || triangles == nullptr ||
		triangleCount < 1 || settings == nullptr)
		return NoBody;
	for (size_t i = 0; i < (size_t)triangleCount * 3; i++)
	{
		if (triangles[i] >= (uint32_t)vertexCount)
			return NoBody;
	}

	const bool cloth = settings->kind == 0;
	const bool jelly = settings->kind == 1;
	const bool shell = settings->kind == 2;
	const bool driven = settings->kind == 3;
	const bool impactSkin = shell && settings->impacts != 0;
	const R3Vector offset = V(center);
	std::vector<R3Vector> worldPositions;
	worldPositions.reserve((size_t)vertexCount + 1);
	std::vector<uint32_t> pinnedIndices;
	for (int32_t i = 0; i < vertexCount; i++)
	{
		worldPositions.push_back(Add(V(&positions[i * 3]), offset));
		if (impactSkin || (pinned != nullptr && pinned[i] >= 0.5f))
			pinnedIndices.push_back((uint32_t)i);
	}

	std::vector<R3Tetrahedron> cells;
	float restVolume = 0.0f;
	const bool fillsInterior = jelly && BuildJellyCells(worldPositions, offset, triangles, triangleCount, cells, restVolume);
	const bool painted = stiffness != nullptr && std::any_of(stiffness, stiffness + vertexCount,
		[](float scale) { return scale < 1.0f; });
	const bool elastic = fillsInterior && !painted && settings->tear == 0;
	if (elastic)
		worldPositions.push_back(offset);

	R3SoftBodyDesc desc = r3DefaultSoftBodyDesc();
	desc.kind = elastic || impactSkin ? R3_SOFT_DESC_PARTICLES : R3_SOFT_DESC_SURFACE;
	desc.positions = R3VectorView{worldPositions.data(), worldPositions.size()};
	desc.surface = R3SurfaceElementView{reinterpret_cast<const R3Triangle*>(triangles), (size_t)triangleCount};
	desc.pinned = R3IndexView{pinnedIndices.data(), pinnedIndices.size()};
	desc.particleMass = std::max(totalMass, 0.001f) / (float)std::max(worldPositions.size() - pinnedIndices.size(), size_t{1});
	desc.particleRadius = R3OptionalReal{1, std::max(settings->vertexRadius, 0.0f)};
	desc.linearDamping = std::max(settings->damping, 0.0f);
	desc.gravityScale = settings->gravityFactor;
	desc.canSleep = driven ? 0 : 1;
	desc.collisionEnabled = !impactSkin && !driven;
	desc.oriented = R3OptionalBool{(uint8_t)(cloth || shell), 0};
	desc.selfContacts = cloth;
	desc.additionalPgsIterations = (size_t)std::clamp(settings->iterations, 1, 32);
	desc.collider.collisionGroups = R3InteractionGroups{settings->memberships, settings->filter, 0};
	desc.collider.solverGroups = desc.collider.collisionGroups;
	desc.collider.activeHooks = R3_FILTER_CONTACT_PAIRS | R3_FILTER_INTERSECTION_PAIR;
	desc.collider.activeEvents = 0; // contacts come from the narrow phase's pair lists
	desc.collider.friction = std::max(settings->friction, 0.0f);
	desc.collider.restitution = std::clamp(settings->restitution, 0.0f, 1.0f);
	const float stretch = std::clamp(settings->surfaceStiffness, 0.0f, 1.0f);
	const float bend = jelly ? 0.2f : std::clamp(settings->bendStiffness, 0.0f, 1.0f);
	const float frequency = 15.0f * std::pow(130.0f / 15.0f, stretch);
	desc.material.edgeSoftness = R3SpringCoefficients{frequency, 0.9f};
	desc.material.bendSoftness = R3SpringCoefficients{bend > 0.0f ? 1.5f * std::pow(12.0f, bend) : 0.0f, 0.9f};
	desc.material.volumeSoftness = R3SpringCoefficients{elastic ? 65.0f : 25.0f, 0.9f};
	desc.material.deformationDamping = jelly ? std::max(settings->wobbleDamping, 0.0f) : 0.0f;
	if (driven)
	{
		const float spring = std::clamp(settings->visualSpring, 0.0f, 1.0f);
		const float persistence = std::clamp(settings->visualDamping, 0.0f, 1.0f);
		desc.material.shapeMatchingSoftness = R3SpringCoefficients{2.0f + 38.0f * spring, 1.25f - persistence};
	}
	desc.shapeMatching = R3OptionalBool{1, (uint8_t)(driven || (jelly && !elastic && settings->tear == 0))};
	desc.volumePreservation = jelly && restVolume > 0.0f;
	if (elastic)
	{
		desc.cells = R3CellView{cells.data(), cells.size()};
		desc.cellModel = R3_SOFT_CELL_COROTATIONAL;
		desc.material.youngModulus = 300.0f * std::pow(14.0f, stretch);
		desc.material.poissonRatio = 0.35f;
		desc.material.elasticDampingRatio = 0.5f;
	}
	if (cloth && !painted && bend > 0.0f && settings->tear == 0 &&
		SetClothGrid(desc, worldPositions, triangles, (size_t)triangleCount))
	{
		desc.warpSoftness = desc.material.edgeSoftness;
		desc.weftSoftness = desc.material.edgeSoftness;
		desc.shearSoftness = R3SpringCoefficients{frequency * 0.7f, 0.9f};
	}
	std::vector<R3SoftEdgeSoftness> edgeSoftness;
	const bool plasticSurface = shell && !impactSkin;
	float meanEdgeLength = 1.0f;
	if (desc.kind == R3_SOFT_DESC_SURFACE && (painted || plasticSurface))
	{
		// The surface recipe numbers edges in first-seen order. Send native overrides for painted edges only.
		std::unordered_set<uint64_t> seen;
		float edgeLengthSum = 0.0f;
		for (int32_t t = 0; t < triangleCount; t++)
		{
			const uint32_t* face = triangles + t * 3;
			for (int edge = 0; edge < 3; edge++)
			{
				const uint32_t a = face[edge], b = face[(edge + 1) % 3];
				if (!seen.insert(SoftEdgeKey(a, b)).second)
					continue;
				if (plasticSurface)
					edgeLengthSum += Length(Sub(worldPositions[a], worldPositions[b]));
				const float scale = painted ? std::clamp((stiffness[a] + stiffness[b]) * 0.5f, 0.02f, 1.0f) : 1.0f;
				if (scale < 1.0f)
					edgeSoftness.push_back(R3SoftEdgeSoftness{(uint32_t)seen.size() - 1, {frequency * std::sqrt(scale), 0.9f}});
			}
		}
		desc.edgeSoftness = R3SoftEdgeSoftnessView{edgeSoftness.data(), edgeSoftness.size()};
		if (plasticSurface && !seen.empty())
			meanEdgeLength = std::max(edgeLengthSum / (float)seen.size(), 1.0e-3f);
	}
	if (plasticSurface)
	{
		// The component stores metres. Rapier's plasticity uses strain relative to an edge's rest length.
		desc.material.edgePlasticYield = std::max(settings->dentYield, 0.001f) / meanEdgeLength;
		desc.material.edgePlasticCreep = 12.0f;
		desc.material.edgePlasticMax = std::max(settings->dentDepth, 0.01f) / meanEdgeLength;
		desc.material.edgePlasticFlow = R3_SOFT_EDGE_PLASTIC_FLOW_BOTH;
	}
	if (settings->tear != 0 && !impactSkin)
	{
		desc.material.tearStrain = R3OptionalReal{1, 0.3f};
		desc.material.tearForce = R3OptionalReal{1, 0.02f};
		desc.material.tearSmoothing = 0.02f;
		desc.material.maxTearsPerStep = 16;
		desc.material.minPiece = R3OptionalU32{0, 0};
	}

	const uint32_t id = AllocateId(world, NoBody);
	desc.userData = R3UserData{id, 0};
	desc.collider.userData = R3UserData{id, SoftColliderTag};
	const R3SoftBodyHandle handle = r3InsertSoftBody(world->world, &desc);
	if (!Valid(handle))
		return NoBody;

	SoftBody* soft = new SoftBody();
	soft->handle = handle;
	soft->count = vertexCount;
	soft->userData = userData;
	soft->kind = settings->kind;
	soft->impacts = settings->impacts;
	soft->visualOnly = driven;
	soft->tear = settings->tear != 0 && !impactSkin;
	soft->hasInteriorParticle = elastic;
	soft->dentDepth = settings->dentDepth;
	soft->dentYield = settings->dentYield;
	soft->dentSpeed = settings->dentSpeed;
	if (driven)
		soft->drivenCenter = r3SoftBody_CenterOfMass(handle);
	soft->friction = std::max(settings->friction, 0.0f);
	soft->restVolume = restVolume;
	soft->totalMass = std::max(totalMass, 0.001f);
	soft->particleMass = desc.particleMass;
	soft->radius = desc.particleRadius.value;
	soft->triangles.assign(triangles, triangles + (size_t)triangleCount * 3);
	soft->restLocal.resize((size_t)vertexCount);
	if (soft->impacts != 0)
		soft->dents.assign((size_t)vertexCount, V(0, 0, 0));
	if (objectMatrix != nullptr)
	{
		float inverse[16];
		MatInvert(objectMatrix, inverse);
		if (driven)
			std::copy_n(inverse, 16, soft->drivenBindInverse);
		for (int32_t i = 0; i < vertexCount; i++)
			soft->restLocal[(size_t)i] = MatPoint(inverse, worldPositions[(size_t)i]);
		for (int i = 0; i < 16; i++)
			soft->lastObject[i] = objectMatrix[i];
		soft->hasObject = true;
	}
	else
	{
		for (int32_t i = 0; i < vertexCount; i++)
			soft->restLocal[(size_t)i] = V(&positions[i * 3]);
		if (driven)
			MatIdentity(soft->drivenBindInverse);
		MatIdentity(soft->lastObject);
	}
	world->softBodies[id] = soft;
	const R3RigidBodyHandle root = r3SoftBody_RootBody(handle);
	if (Valid(root))
		r3RigidBody_SetUserData(root, R3UserData{id, 0});
	soft->hasCollider = r3SoftBody_MeshColliders(handle, nullptr, 0) != 0;
	if (soft->hasCollider)
	{
		Body& info = soft->collisionInfo;
		info.handle = root;
		info.userData = userData;
		info.objectCode = settings->objectCode;
		info.group = settings->group;
		info.motionClass = settings->motionClass;
		info.memberships = settings->memberships;
		info.filter = settings->filter;
		world->MarkQueryFull();
	}
	return id;
}

namespace
{
	SoftBody* SoftOf(World* world, uint32_t id)
	{
		if (world == nullptr)
			return nullptr;
		auto it = world->softBodies.find(id);
		return it == world->softBodies.end() ? nullptr : it->second;
	}

	R3Vector SoftLocal(SoftBody* soft, R3Vector worldPosition)
	{
		if (!soft->hasObject)
			return worldPosition;
		float inverse[16];
		MatInvert(soft->lastObject, inverse);
		return MatPoint(inverse, worldPosition);
	}

	void SetParticle(SoftBody* soft, size_t index, R3Vector position)
	{
		r3SoftBody_SetParticlePosition(soft->handle, index, position);
	}
}

namespace
{
	void RestoreShellColliders(World* world, SoftBody* soft)
	{
		if (!Valid(soft->deformable))
			return;
		world->deformableOwners.erase(ColliderKey(soft->deformable));
		r3RemoveCollider(soft->deformable, 0);
		soft->deformable = R3ColliderHandle{nullptr, UINT32_MAX, 0};
		if (Body* carrier = world->Find(soft->ignoredBody))
		{
			if (Valid(soft->replacedCollider))
				r3Collider_SetEnabled(soft->replacedCollider, 1);
			if (soft->hasCarrierMassProperties)
			{
				R3MassProperties empty{};
				empty.principal_inertia_local_frame.w = 1.0f;
				r3RigidBody_SetAdditionalMassProperties(carrier->handle, empty, 1);
				r3RigidBody_RecomputeMassPropertiesFromColliders(carrier->handle);
			}
			carrier->shellSurface = soft->deformable;
			UpdateFilterHooks(*carrier);
		}
		soft->replacedCollider = R3ColliderHandle{nullptr, UINT32_MAX, 0};
		soft->hasCarrierMassProperties = false;
		soft->dentedContacts.clear();
		if (soft->attachedToCarrier)
		{
			for (size_t i = 0; i < soft->dents.size(); i++)
			{
				r3SoftBody_DetachParticle(soft->handle, i);
				r3SoftBody_SetParticlePinned(soft->handle, i, 1);
			}
			soft->attachedToCarrier = false;
		}
		world->MarkQueryFull();
	}
}

int32_t tn_rapier_soft_has_collider(void* raw, uint32_t body)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	return soft != nullptr && (soft->hasCollider || Valid(soft->deformable)) ? 1 : 0;
}

void tn_rapier_soft_destroy(void* raw, uint32_t body)
{
	World* world = static_cast<World*>(raw);
	SoftBody* soft = SoftOf(world, body);
	if (soft == nullptr)
		return;
	RestoreShellColliders(world, soft);
	if (Valid(soft->handle))
		r3RemoveSoftBody(soft->handle);
	world->softBodies.erase(body);
	world->MarkQueryFull();
	delete soft;
}

void tn_rapier_soft_ignore(void* raw, uint32_t body, uint32_t ignoredBody)
{
	World* world = static_cast<World*>(raw);
	SoftBody* soft = SoftOf(world, body);
	if (soft == nullptr)
		return;
	if (soft->kind == 4)
	{
		if (ignoredBody == NoBody)
			soft->ignoredBody = soft->secondRopeEnd = NoBody;
		else if (soft->ignoredBody == NoBody)
			soft->ignoredBody = ignoredBody;
		else if (soft->ignoredBody != ignoredBody)
			soft->secondRopeEnd = ignoredBody;
		return;
	}
	if (soft->ignoredBody != ignoredBody)
		RestoreShellColliders(world, soft);
	soft->ignoredBody = ignoredBody;
	// A shell in FromImpacts mode uses the object's collider for hits. Give that object a Rapier deformable
	// trimesh collider bound to the shell's particles, so its collision surface follows the dents instead of the
	// engine re-wrapping a convex hull after they settle. The ordinary colliders are switched off while this one
	// is in charge.
	if (soft->kind != 2 || soft->impacts == 0 || ignoredBody == NoBody || Valid(soft->deformable))
		return;
	Body* shellBody = world->Find(ignoredBody);
	if (shellBody == nullptr || soft->triangles.empty() || soft->count < 3)
		return;
	if (shellBody->sensor || Valid(shellBody->shellSurface) || shellBody->colliders.size() != 1 ||
		(soft->userData != 0 && soft->userData != shellBody->userData))
		return;
	const R3ColliderHandle original = shellBody->colliders.front();
	if (!r3Collider_IsEnabled(original))
		return;
	// Deformable colliders bind through a soft body's root body, not an ordinary rigid body.
	const R3RigidBodyHandle parent = r3SoftBody_RootBody(soft->handle);
	if (!Valid(parent))
		return;
	const R3Pose pose = r3RigidBody_Position(parent);
	float bodyMatrix[16], inverse[16];
	MatFromPose(pose, bodyMatrix);
	if (!MatInvert(bodyMatrix, inverse))
		return;
	std::vector<R3Vector> positions((size_t)soft->count);
	const size_t count = r3SoftBody_ParticlePositions(soft->handle, positions.data(), positions.size());
	if (count < 3)
		return;
	for (uint32_t index : soft->triangles)
	{
		if (index >= count)
			return;
	}
	std::vector<R3Vector> local((size_t)count);
	for (size_t i = 0; i < count; i++)
		local[i] = MatPoint(inverse, positions[i]);
	R3ColliderDesc collider = r3DefaultColliderDesc();
	r3ShapeDesc_SetTrimesh(&collider.shape, (R3VectorView){local.data(), count},
		(R3TriangleView){reinterpret_cast<const R3Triangle*>(soft->triangles.data()), soft->triangles.size() / 3},
		R3_TRIMESH_DEFORMABLE);
	collider.position = R3Pose{V(0, 0, 0), R3Rotation{0, 0, 0, 1}};
	collider.friction = soft->friction;
	collider.restitution = 0.0f;
	collider.isSensor = 0;
	collider.collisionGroups = r3Collider_CollisionGroups(original);
	collider.solverGroups = r3Collider_SolverGroups(original);
	collider.activeEvents = 0; // contacts come from the narrow phase's pair lists
	collider.activeHooks = R3_FILTER_CONTACT_PAIRS | R3_FILTER_INTERSECTION_PAIR;
	R3SoftMeshBindingDesc binding = r3DefaultSoftMeshBindingDesc();
	binding.kind = R3_SOFT_BINDING_DIRECT;
	std::vector<uint32_t> particles((size_t)count);
	for (size_t i = 0; i < count; i++)
		particles[i] = (uint32_t)i;
	binding.particles = R3IndexView{particles.data(), particles.size()};
	const R3ColliderHandle handle = r3InsertDeformableCollider(&collider, &binding, parent);
	if (!Valid(handle))
		return;
	soft->deformable = handle;
	world->deformableOwners[ColliderKey(handle)] = ignoredBody;
	shellBody->shellSurface = handle;
	UpdateFilterHooks(*shellBody);
	if (shellBody->motion == 2)
	{
		// Transfer the authored mass and angular inertia into the carrier itself before disabling its shape.
		R3MassProperties mass = r3Collider_MassProperties(original);
		const R3Pose localPose = r3Collider_PositionWrtParent(original);
		mass.local_com = Add(localPose.translation, QRot(localPose.rotation, mass.local_com));
		mass.principal_inertia_local_frame = QNorm(QMul(localPose.rotation, mass.principal_inertia_local_frame));
		if (mass.mass <= 0.0f || r3RigidBody_SetAdditionalMassProperties(shellBody->handle, mass, 1) != R3_OK)
		{
			RestoreShellColliders(world, soft);
			return;
		}
		soft->hasCarrierMassProperties = true;
		// The native point attachments transfer contact loads from each particle to the Rigidbody.
		soft->attachedToCarrier = true;
		for (size_t i = 0; i < count; i++)
		{
			if (r3SoftBody_SetParticlePinned(soft->handle, i, 0) != R3_OK ||
				r3SoftBody_AttachParticle(soft->handle, i, shellBody->handle) != R3_OK)
			{
				RestoreShellColliders(world, soft);
				return;
			}
		}
	}
	if (r3Collider_SetEnabled(original, 0) != R3_OK)
	{
		RestoreShellColliders(world, soft);
		return;
	}
	soft->replacedCollider = original;
	if (soft->hasCarrierMassProperties)
		r3RigidBody_RecomputeMassPropertiesFromColliders(shellBody->handle);
	world->MarkQueryFull();
}

void tn_rapier_soft_skin(void* raw, uint32_t body, const float objectMatrix[16], const float objectNext[16],
	float step)
{
	World* world = static_cast<World*>(raw);
	SoftBody* soft = SoftOf(world, body);
	if (soft == nullptr || !Valid(soft->handle) || objectMatrix == nullptr || objectNext == nullptr)
		return;
	if (soft->kind == 2 && soft->impacts != 0)
	{
		std::copy_n(objectNext, 16, soft->lastObject);
		soft->hasObject = true;
		soft->followsDynamicBody = false;
		const Body* carrier = world->Find(soft->ignoredBody);
		if (carrier != nullptr && carrier->motion == 2 && Valid(carrier->handle))
		{
			float rigid[16], inverseRigid[16];
			MatFromPose(r3RigidBody_Position(carrier->handle), rigid);
			if (MatInvert(rigid, inverseRigid))
			{
				MatMul(inverseRigid, objectMatrix, soft->objectFromBody);
				soft->followsDynamicBody = true;
			}
		}
		if (soft->attachedToCarrier)
			return;
		for (size_t i = 0; i < soft->dents.size(); i++)
		{
			const R3Vector target = MatPoint(objectNext, Add(soft->restLocal[i], soft->dents[i]));
			if (Valid(soft->deformable))
				r3SoftBody_SetParticleKinematicTarget(soft->handle, i, target);
			else if (!soft->followsDynamicBody)
				SetParticle(soft, i, target);
		}
		return;
	}
	if (soft->visualOnly)
	{
		// The cluster follows a rigid target in Rapier's solver. Clamp very large teleports
		// to the authored maximum flex, then let the spring and damping settle the remainder.
		float motion[16];
		MatMul(objectNext, soft->drivenBindInverse, motion);
		const R3Pose target{MatPoint(motion, soft->drivenCenter), MatRotation(motion)};
		r3SoftBody_SetClusterShapeMatchingTarget(soft->handle, 0, &target);
		std::vector<R3Vector> particles(r3SoftBody_NumParticles(soft->handle));
		const size_t count = std::min({r3SoftBody_ParticlePositions(soft->handle, particles.data(), particles.size()),
			particles.size(), soft->restLocal.size()});
		for (size_t i = 0; i < count; i++)
		{
			const R3Vector goal = MatPoint(objectNext, soft->restLocal[i]);
			const R3Vector gap = Sub(particles[i], goal);
			const float distance = Length(gap);
			if (distance > soft->dentDepth && distance > 1.0e-6f)
				SetParticle(soft, i, Add(goal, Scale(gap, soft->dentDepth / distance)));
		}
		r3SoftBody_WakeUp(soft->handle);
		return;
	}
	(void)step;
	float inverse[16];
	if (!MatInvert(soft->lastObject, inverse))
		return;
	float delta[16];
	MatMul(objectNext, inverse, delta);
	std::vector<R3Vector> buffer(r3SoftBody_NumParticles(soft->handle));
	const size_t count = std::min(r3SoftBody_ParticlePositions(soft->handle, buffer.data(), buffer.size()), buffer.size());
	for (size_t i = 0; i < count; i++)
		SetParticle(soft, i, MatPoint(delta, buffer[i]));
	for (int i = 0; i < 16; i++)
		soft->lastObject[i] = objectNext[i];
	soft->hasObject = true;
	r3SoftBody_WakeUp(soft->handle);
}

uint32_t tn_rapier_soft_count(void* raw, uint32_t body)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	return soft != nullptr ? (uint32_t)soft->count : 0;
}

uint32_t tn_rapier_soft_read(void* raw, uint32_t body, float* positions, float* velocities, uint32_t capacity)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || capacity == 0)
		return 0;
	std::vector<R3Vector> buffer(r3SoftBody_NumParticles(soft->handle));
	const size_t count = std::min({(size_t)soft->count, (size_t)capacity, buffer.size()});
	if (positions != nullptr)
	{
		if (r3SoftBody_ParticlePositions(soft->handle, buffer.data(), buffer.size()) < count)
			return 0;
		for (size_t i = 0; i < count; i++)
			Out(&positions[i * 3], buffer[(size_t)i]);
	}
	if (velocities != nullptr)
	{
		if (r3SoftBody_ParticleVelocities(soft->handle, buffer.data(), buffer.size()) < count)
			return 0;
		for (size_t i = 0; i < count; i++)
			Out(&velocities[i * 3], buffer[(size_t)i]);
	}
	return (uint32_t)count;
}

void tn_rapier_soft_move_pinned(void* raw, uint32_t body, const uint32_t* indices, const float* targets,
	uint32_t count, const float center[3])
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle))
		return;
	(void)center;
	for (uint32_t i = 0; i < count; i++)
	{
		r3SoftBody_SetParticlePinned(soft->handle, indices[i], 1);
		r3SoftBody_SetParticleKinematicTarget(soft->handle, indices[i], V(&targets[i * 3]));
	}
	r3SoftBody_WakeUp(soft->handle);
}

void tn_rapier_soft_set_positions(void* raw, uint32_t body, const float* positions, const float* velocities,
	uint32_t count, const float center[3])
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || positions == nullptr)
		return;
	(void)center;
	const uint32_t limit = std::min(count, (uint32_t)soft->count);
	for (uint32_t i = 0; i < limit; i++)
	{
		r3SoftBody_SetParticlePosition(soft->handle, i, V(&positions[i * 3]));
		if (velocities != nullptr)
			r3SoftBody_SetParticleVelocity(soft->handle, i, V(&velocities[i * 3]));
	}
	if (soft->hasInteriorParticle && limit == (uint32_t)soft->count)
	{
		R3Vector position = V(0, 0, 0);
		R3Vector velocity = V(0, 0, 0);
		for (uint32_t i = 0; i < limit; i++)
		{
			position = Add(position, V(&positions[i * 3]));
			if (velocities != nullptr)
				velocity = Add(velocity, V(&velocities[i * 3]));
		}
		const float share = 1.0f / (float)limit;
		SetParticle(soft, limit, Scale(position, share));
		if (velocities != nullptr)
			r3SoftBody_SetParticleVelocity(soft->handle, limit, Scale(velocity, share));
	}
	r3SoftBody_WakeUp(soft->handle);
}

void tn_rapier_soft_velocity(void* raw, uint32_t body, float* velocity)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (velocity == nullptr)
		return;
	velocity[0] = velocity[1] = velocity[2] = 0;
	if (soft == nullptr || !Valid(soft->handle))
		return;
	std::vector<R3Vector> buffer(r3SoftBody_NumParticles(soft->handle));
	const size_t count = r3SoftBody_ParticleVelocities(soft->handle, buffer.data(), buffer.size());
	R3Vector sum = V(0, 0, 0);
	for (size_t i = 0; i < count; i++)
		sum = Add(sum, buffer[i]);
	if (count > 0)
		Out(velocity, Scale(sum, 1.0f / (float)count));
}

void tn_rapier_soft_set_velocity(void* raw, uint32_t body, const float* velocity)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || velocity == nullptr)
		return;
	const R3Vector value = V(velocity);
	const size_t count = r3SoftBody_NumParticles(soft->handle);
	for (size_t i = 0; i < count; i++)
		r3SoftBody_SetParticleVelocity(soft->handle, i, value);
	r3SoftBody_WakeUp(soft->handle);
}

void tn_rapier_soft_impulse(void* raw, uint32_t body, const float* impulse)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft != nullptr && Valid(soft->handle) && impulse != nullptr)
		r3SoftBody_ApplyImpulse(soft->handle, Scale(V(impulse), 1.0f / soft->totalMass), 1);
}

void tn_rapier_soft_force(void* raw, uint32_t body, const float* force, float step)
{
	if (force == nullptr || step <= 0.0f)
		return;
	const R3Vector impulse = Scale(V(force), step);
	const float packed[3] = {impulse.x, impulse.y, impulse.z};
	tn_rapier_soft_impulse(raw, body, packed);
}

void tn_rapier_soft_shift(void* raw, uint32_t body, const float* offset)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || offset == nullptr)
		return;
	const R3Vector delta = V(offset);
	std::vector<R3Vector> buffer(r3SoftBody_NumParticles(soft->handle));
	const size_t count = r3SoftBody_ParticlePositions(soft->handle, buffer.data(), buffer.size());
	for (size_t i = 0; i < count; i++)
		SetParticle(soft, i, Add(buffer[i], delta));
	r3SoftBody_WakeUp(soft->handle);
}

int32_t tn_rapier_soft_bounds(void* raw, uint32_t body, float* minimum, float* maximum)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || minimum == nullptr || maximum == nullptr || soft->count == 0)
		return 0;
	std::vector<R3Vector> buffer(r3SoftBody_NumParticles(soft->handle));
	const size_t count = r3SoftBody_ParticlePositions(soft->handle, buffer.data(), buffer.size());
	if (count == 0)
		return 0;
	R3Vector lo = buffer[0], hi = buffer[0];
	for (size_t i = 1; i < count; i++)
	{
		lo = V(std::min(lo.x, buffer[i].x), std::min(lo.y, buffer[i].y), std::min(lo.z, buffer[i].z));
		hi = V(std::max(hi.x, buffer[i].x), std::max(hi.y, buffer[i].y), std::max(hi.z, buffer[i].z));
	}
	Out(minimum, lo);
	Out(maximum, hi);
	return 1;
}

void tn_rapier_soft_set_pressure(void* raw, uint32_t body, float amount)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || soft->kind != 1 || soft->restVolume <= 1.0e-8f)
		return;
	// The engine sends rest pressure times volume. Rapier needs a target volume ratio; at the
	// default 10 Pa, a jelly should stay close to its rest size.
	constexpr float bulkModulus = 150.0f;
	const float pressure = std::max(amount, 0.0f) / soft->restVolume;
	r3SoftBody_SetVolumeFactor(soft->handle, 1.0f + pressure / bulkModulus);
	r3SoftBody_WakeUp(soft->handle);
}

namespace
{
	void ApplyDragImpulse(SoftBody* soft, size_t particle, R3Vector impulse, R3Vector relativeAir)
	{
		// Integrate quadratic drag without overshooting the air velocity on a large fixed step.
		// A heavy impact can give a light sheet large velocities and temporarily stretch its faces.
		const float momentum = soft->particleMass * Length(relativeAir);
		const float magnitude = Length(impulse);
		if (std::isfinite(magnitude) && magnitude > 0.0f && std::isfinite(momentum) && momentum > 0.0f)
		{
			const float scale = momentum / (momentum + magnitude);
			r3SoftBody_ApplyParticleImpulse(soft->handle, particle, Scale(impulse, scale), 0);
		}
	}
}

void tn_rapier_soft_wind(void* raw, uint32_t body, const float wind[3], float drag, float turbulence,
	float time, float step)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || wind == nullptr || drag <= 0.0f || step <= 0.0f ||
		soft->triangles.size() < 3)
		return;
	const size_t particles = r3SoftBody_NumParticles(soft->handle);
	std::vector<R3Vector> positions(particles);
	std::vector<R3Vector> velocities(particles);
	const size_t read = r3SoftBody_ParticlePositions(soft->handle, positions.data(), positions.size());
	const size_t count = std::min({read, particles, (size_t)soft->count});
	r3SoftBody_ParticleVelocities(soft->handle, velocities.data(), velocities.size());
	if (count == 0)
		return;
	const float density = 1.2f;
	const float along = 0.1f;
	const R3Vector air = V(wind);
	std::vector<R3Vector> impulses(count, V(0, 0, 0));
	for (size_t t = 0; t + 2 < soft->triangles.size(); t += 3)
	{
		const uint32_t ia = soft->triangles[t], ib = soft->triangles[t + 1], ic = soft->triangles[t + 2];
		if (ia >= count || ib >= count || ic >= count)
			continue;
		const R3Vector a = positions[ia], b = positions[ib], c = positions[ic];
		R3Vector normal = Cross(Sub(b, a), Sub(c, a));
		const float twiceArea = Length(normal);
		if (twiceArea < 1.0e-9f)
			continue;
		normal = Scale(normal, 1.0f / twiceArea);
		const R3Vector middle = Scale(Add(Add(a, b), c), 1.0f / 3.0f);
		R3Vector localAir = air;
		if (turbulence > 0.0f)
		{
			const float phase = Dot(middle, V(2.1f, 1.7f, 2.3f)) + time * 3.1f;
			localAir = Scale(localAir, 1.0f + turbulence * 0.25f * std::sin(phase));
		}
		const R3Vector relative = Sub(localAir, Scale(Add(Add(velocities[ia], velocities[ib]), velocities[ic]), 1.0f / 3.0f));
		const float into = Dot(normal, relative);
		const R3Vector sliding = Sub(relative, Scale(normal, into));
		const float share = 0.5f * density * drag * 0.5f * twiceArea * step / 3.0f;
		const R3Vector impulse = Scale(Add(Scale(normal, into * std::fabs(into)), Scale(sliding, along * Length(sliding))), share);
		impulses[ia] = Add(impulses[ia], impulse);
		impulses[ib] = Add(impulses[ib], impulse);
		impulses[ic] = Add(impulses[ic], impulse);
	}
	for (size_t i = 0; i < count; i++)
		ApplyDragImpulse(soft, i, impulses[i], Sub(air, velocities[i]));
	r3SoftBody_WakeUp(soft->handle);
}

uint32_t tn_rapier_soft_dents(void* raw, uint32_t body, float* output, uint32_t capacity)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || output == nullptr)
		return 0;
	std::vector<R3Vector> buffer(r3SoftBody_NumParticles(soft->handle));
	const size_t read = r3SoftBody_ParticlePositions(soft->handle, buffer.data(), buffer.size());
	const uint32_t count = (uint32_t)std::min((size_t)soft->count, (size_t)capacity);
	float sum = 0.0f;
	for (uint32_t i = 0; i < count && i < read; i++)
	{
		const R3Vector dent = i < soft->dents.size() ? soft->dents[i] :
			Sub(SoftLocal(soft, buffer[i]), soft->restLocal[i]);
		Out(&output[i * 3], dent);
		sum += Length(dent);
	}
	if (std::fabs(sum - soft->lastDentSum) > 1.0e-5f)
	{
		soft->lastDentSum = sum;
		soft->dentRevision++;
	}
	return count;
}

uint32_t tn_rapier_soft_dent_revision(void* raw, uint32_t body)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr)
		return 0;
	return soft->dentRevision;
}

namespace
{
	void PlaceDentVertex(SoftBody* soft, const Body* carrier, size_t index, R3Vector dent)
	{
		const R3Vector position = MatPoint(soft->lastObject, Add(soft->restLocal[index], dent));
		if (soft->attachedToCarrier && carrier != nullptr)
		{
			// The attachment takes its local anchor from the particle's current world position.
			r3SoftBody_DetachParticle(soft->handle, index);
			SetParticle(soft, index, position);
			r3SoftBody_SetParticleVelocity(soft->handle, index, r3RigidBody_VelocityAtPoint(carrier->handle, position));
			r3SoftBody_AttachParticle(soft->handle, index, carrier->handle);
		}
		else if (Valid(soft->deformable))
			r3SoftBody_SetParticleKinematicTarget(soft->handle, index, position);
		else
			SetParticle(soft, index, position);
	}

	void SetDentVertex(SoftBody* soft, const Body* carrier, size_t index, R3Vector dent)
	{
		soft->dents[index] = dent;
		if (Valid(soft->deformable))
			soft->pendingDentVertices.push_back(index);
		else
			PlaceDentVertex(soft, carrier, index, dent);
	}

	void UpdateShellObjectFromCarrier(SoftBody* soft, const Body& carrier)
	{
		if (soft->followsDynamicBody)
		{
			float rigid[16];
			MatFromPose(r3RigidBody_Position(carrier.handle), rigid);
			MatMul(rigid, soft->objectFromBody, soft->lastObject);
		}
	}

	void ApplyPendingShellDents(World* world)
	{
		for (auto& entry : world->softBodies)
		{
			SoftBody* soft = entry.second;
			auto& pending = soft->pendingDentVertices;
			if (pending.empty())
				continue;
			const Body* carrier = world->Find(soft->ignoredBody);
			if (carrier != nullptr)
				UpdateShellObjectFromCarrier(soft, *carrier);
			// Rapier refits the bound mesh during a physics step. Apply edits to the
			// particles before that step so render readback and queries agree.
			std::sort(pending.begin(), pending.end());
			const auto end = std::unique(pending.begin(), pending.end());
			for (auto it = pending.begin(); it != end; ++it)
				PlaceDentVertex(soft, carrier, *it, soft->dents[*it]);
			pending.clear();
		}
	}
}

void tn_rapier_soft_set_dents(void* raw, uint32_t body, const float* dents, uint32_t count,
	const float objectMatrix[16])
{
	World* world = static_cast<World*>(raw);
	SoftBody* soft = SoftOf(world, body);
	if (soft == nullptr || !Valid(soft->handle))
		return;
	if (objectMatrix != nullptr)
	{
		for (int i = 0; i < 16; i++)
			soft->lastObject[i] = objectMatrix[i];
		soft->hasObject = true;
	}
	const Body* carrier = world->Find(soft->ignoredBody);
	const size_t limit = dents == nullptr ? soft->dents.size() : std::min((size_t)count, soft->dents.size());
	for (size_t i = 0; i < limit; i++)
		SetDentVertex(soft, carrier, i, dents != nullptr ? V(&dents[i * 3]) : V(0, 0, 0));
	soft->dentRevision++;
	soft->lastDentSum = 0.0f;
	r3SoftBody_WakeUp(soft->handle);
}

int32_t tn_rapier_soft_torn(void* raw, uint32_t body)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	return soft != nullptr && soft->torn ? 1 : 0;
}

uint32_t tn_rapier_soft_float(void* raw, uint32_t body, const float* samples, uint32_t nx, uint32_t nz,
	float minX, float minZ, float cellX, float cellZ, float bottom, float band, float buoyancy, float drag,
	float gravity, float deltaTime, int32_t wake)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || samples == nullptr || nx == 0 || nz == 0 || deltaTime <= 0.0f)
		return 0;
	std::vector<R3Vector> positions(r3SoftBody_NumParticles(soft->handle));
	std::vector<R3Vector> velocities(r3SoftBody_NumParticles(soft->handle));
	const size_t count = r3SoftBody_ParticlePositions(soft->handle, positions.data(), positions.size());
	r3SoftBody_ParticleVelocities(soft->handle, velocities.data(), velocities.size());
	uint32_t underCount = 0;
	const float safeCellX = std::max(cellX, 1.0e-4f), safeCellZ = std::max(cellZ, 1.0e-4f);
	const float safeBand = std::max(band, 1.0e-3f);
	for (size_t i = 0; i < count; i++)
	{
		const R3Vector p = positions[i];
		float fx = (p.x - minX) / safeCellX;
		float fz = (p.z - minZ) / safeCellZ;
		fx = std::clamp(fx, 0.0f, (float)(nx - 1));
		fz = std::clamp(fz, 0.0f, (float)(nz - 1));
		const uint32_t ix = (uint32_t)std::min((float)(nx - 1), std::floor(fx));
		const uint32_t iz = (uint32_t)std::min((float)(nz - 1), std::floor(fz));
		const uint32_t ix1 = std::min(ix + 1, nx - 1), iz1 = std::min(iz + 1, nz - 1);
		const float tx = fx - (float)ix, tz = fz - (float)iz;
		const float s00 = samples[ix * nz + iz], s10 = samples[ix1 * nz + iz];
		const float s01 = samples[ix * nz + iz1], s11 = samples[ix1 * nz + iz1];
		const float surface = (s00 * (1 - tx) + s10 * tx) * (1 - tz) + (s01 * (1 - tx) + s11 * tx) * tz;
		if (p.y >= surface || p.y < bottom)
			continue;
		const float under = std::clamp((surface - p.y) / safeBand, 0.0f, 1.0f);
		R3Vector v = velocities[i];
		v.y += gravity * std::max(buoyancy, 0.0f) * under * deltaTime;
		v = Scale(v, std::exp(-std::max(drag, 0.0f) * under * deltaTime));
		r3SoftBody_SetParticleVelocity(soft->handle, i, v);
		underCount++;
	}
	if (underCount > 0 && wake != 0)
		r3SoftBody_WakeUp(soft->handle);
	return underCount;
}

int32_t tn_rapier_soft_tear(void* raw, uint32_t body)
{
	World* world = static_cast<World*>(raw);
	SoftBody* soft = SoftOf(world, body);
	if (soft == nullptr || !Valid(soft->handle) || !soft->tear)
		return 0;
	std::vector<uint32_t> edgeVertices(2 * 4096);
	size_t count = r3SoftBody_Edges(soft->handle, edgeVertices.data(), edgeVertices.size());
	if (count > edgeVertices.size())
	{
		edgeVertices.resize(count);
		count = r3SoftBody_Edges(soft->handle, edgeVertices.data(), edgeVertices.size());
	}
	const size_t edgeCount = std::min(count, edgeVertices.size()) / 2;
	if (edgeCount == 0)
		return 0;
	std::vector<R3Vector> positions(r3SoftBody_NumParticles(soft->handle));
	const size_t particles = r3SoftBody_ParticlePositions(soft->handle, positions.data(), positions.size());
	std::vector<uint32_t> torn;
	for (size_t i = 0; i < edgeCount; i++)
	{
		const uint32_t a = edgeVertices[i * 2], b = edgeVertices[i * 2 + 1];
		if (a >= particles || b >= particles || a >= soft->restLocal.size() || b >= soft->restLocal.size())
			continue;
		const float rest = Length(Sub(soft->restLocal[b], soft->restLocal[a]));
		if (rest < 1.0e-6f)
			continue;
		const float now = Length(Sub(positions[b], positions[a]));
		if (now / rest > 1.3f)
			torn.push_back((uint32_t)i);
	}
	if (torn.empty())
		return 0;
	r3SoftBody_WakeUp(soft->handle);
	R3SoftBodyTearEvent* event = r3SoftBody_Tear(soft->handle, torn.data(), torn.size(), nullptr, 0);
	if (event == nullptr)
		return 0;
	r3FreeSoftBodyTearEvent(event);
	soft->torn = true;
	soft->dentRevision++;
	return 1;
}

// Shell dents from the object's impacts, and tear-event bookkeeping, run after every step.
namespace
{
	// Outward normals of a shell's rest surface, in its object's space: each vertex's triangles, area-weighted. The
	// winding is taken as given unless the closed surface's signed volume says it is inside out.
	void EnsureRestNormals(SoftBody* soft)
	{
		if (soft->restNormal.size() == soft->restLocal.size())
			return;
		soft->restNormal.assign(soft->restLocal.size(), V(0, 0, 0));
		float volume = 0.0f, edges = 0.0f;
		size_t edgeCount = 0;
		for (size_t t = 0; t + 2 < soft->triangles.size(); t += 3)
		{
			const uint32_t a = soft->triangles[t], b = soft->triangles[t + 1], c = soft->triangles[t + 2];
			if (a >= soft->restLocal.size() || b >= soft->restLocal.size() || c >= soft->restLocal.size())
				continue;
			const R3Vector pa = soft->restLocal[a], pb = soft->restLocal[b], pc = soft->restLocal[c];
			const R3Vector area = Cross(Sub(pb, pa), Sub(pc, pa));
			volume += Dot(pa, Cross(pb, pc));
			edges += Length(Sub(pb, pa)) + Length(Sub(pc, pb)) + Length(Sub(pa, pc));
			edgeCount += 3;
			soft->restNormal[a] = Add(soft->restNormal[a], area);
			soft->restNormal[b] = Add(soft->restNormal[b], area);
			soft->restNormal[c] = Add(soft->restNormal[c], area);
		}
		soft->restEdge = edgeCount > 0 ? edges / (float)edgeCount : 0.0f;
		const float flip = volume < 0.0f ? -1.0f : 1.0f;
		for (R3Vector& n : soft->restNormal)
			n = Scale(Normalize(n), flip);
	}

	// A hit on a shell's object dents the shell where it struck. Strength follows the speed past Dent Speed and how
	// heavy the hitter is against the object; the dent reaches 0.25 to 1 m from the contact (further for faster
	// hits, and never less than one and a half of the mesh's edges) across the struck surface. Only vertices whose surface faces the hit move, each pushed half along the
	// hit and half into its own surface, so a corner or an edge folds in rather than its neighbouring panels sliding
	// sideways. Each hit adds up to Dent Depth (less the Spring Back), to at most three Dent Depths in all.
	bool DentShell(SoftBody* soft, const Body& carrier, const Body* other, R3Vector contact, R3Vector normal,
		float speed)
	{
		if (soft->dentSpeed <= 0.0f || speed <= soft->dentSpeed)
			return false;
		const float hard = std::clamp((speed - soft->dentSpeed) / std::max(soft->dentSpeed * 3.0f, 0.5f), 0.0f, 1.0f);
		const float ownInverse = carrier.motion == 2 ? 1.0f / std::max(r3RigidBody_Mass(carrier.handle), 0.001f) : 0.0f;
		const float otherInverse = other != nullptr && other->motion == 2 ?
			1.0f / std::max(r3RigidBody_Mass(other->handle), 0.001f) : 0.0f;
		float heavy = 1.0f;
		if (ownInverse + otherInverse > 0.0f)
		{
			const float reduced = 1.0f / (ownInverse + otherInverse);
			const float ownMass = ownInverse > 0.0f ? 1.0f / ownInverse : reduced;
			// Full strength from about a fiftieth of the object's mass up; a bullet barely marks a van.
			heavy = std::clamp(reduced / std::max(ownMass * 0.02f, 0.001f), 0.0f, 1.0f);
		}
		const float depth = soft->dentDepth * hard * heavy;
		if (depth < 0.002f)
			return false;
		const float limit = soft->dentDepth * 3.0f;
		float toLocal[16];
		if (!MatInvert(soft->lastObject, toLocal))
			return false;
		const R3Vector into = Normalize(normal);
		if (Length(into) < 1.0e-5f)
			return false;
		EnsureRestNormals(soft);
		// At least one and a half edges: a coarse mesh has no vertex close enough to show a smaller dent.
		const float scale = std::cbrt(std::fabs(
			soft->lastObject[0] * (soft->lastObject[5] * soft->lastObject[10] - soft->lastObject[9] * soft->lastObject[6]) -
			soft->lastObject[4] * (soft->lastObject[1] * soft->lastObject[10] - soft->lastObject[9] * soft->lastObject[2]) +
			soft->lastObject[8] * (soft->lastObject[1] * soft->lastObject[6] - soft->lastObject[5] * soft->lastObject[2])));
		const float reach = std::max(std::clamp(0.25f + 0.04f * speed, 0.25f, 1.0f), soft->restEdge * scale * 1.5f);
		bool changed = false;
		for (size_t i = 0; i < soft->dents.size(); i++)
		{
			// Normals turn by the inverse transpose, so a scaled object keeps them square to its surface.
			const R3Vector n = soft->restNormal[i];
			const R3Vector outward = Normalize(V(toLocal[0] * n.x + toLocal[1] * n.y + toLocal[2] * n.z,
				toLocal[4] * n.x + toLocal[5] * n.y + toLocal[6] * n.z,
				toLocal[8] * n.x + toLocal[9] * n.y + toLocal[10] * n.z));
			// Only the side facing what hit it: not the far wall, nor a panel turned away.
			const float facing = -Dot(outward, into);
			if (facing < -0.3f)
				continue;
			const R3Vector previous = soft->dents[i];
			const R3Vector place = MatPoint(soft->lastObject, Add(soft->restLocal[i], previous));
			const R3Vector gap = Sub(place, contact);
			// Distance across the struck surface, plus how far behind the contact the vertex sits.
			const float behind = std::max(Dot(gap, into), 0.0f);
			const R3Vector across = Sub(gap, Scale(into, Dot(gap, into)));
			const float off = std::sqrt(behind * behind + Dot(across, across));
			float fade = 1.0f - off / reach;
			if (fade <= 0.0f)
				continue;
			fade = fade * fade * (3.0f - 2.0f * fade);
			const float facingWeight = std::clamp((facing + 0.3f) / 0.8f, 0.0f, 1.0f);
			const float push = depth * fade * facingWeight - soft->dentYield;
			if (push <= 0.0f)
				continue;
			R3Vector way = Normalize(Add(into, Scale(outward, -1.0f)));
			if (Length(way) < 1.0e-5f)
				way = into;
			// World-space push into the object's space; the total stays within the limit, in metres.
			R3Vector current = Add(previous, MatDirection(toLocal, Scale(way, push)));
			const float total = Length(MatDirection(soft->lastObject, current));
			if (total > limit)
				current = Scale(current, limit / total);
			if (Length(MatDirection(soft->lastObject, Sub(current, previous))) <= 1.0e-5f)
				continue;
			SetDentVertex(soft, &carrier, i, current);
			changed = true;
		}
		if (changed)
		{
			soft->dentRevision++;
			r3SoftBody_WakeUp(soft->handle);
		}
		return changed;
	}

	void UpdateShellDents(World* world)
	{
		for (auto& entry : world->softBodies)
		{
			SoftBody* soft = entry.second;
			if (soft->kind != 2 || soft->impacts == 0 || soft->ignoredBody == NoBody || !Valid(soft->handle))
				continue;
			const Body* carrier = world->Find(soft->ignoredBody);
			if (carrier == nullptr)
				continue;
			UpdateShellObjectFromCarrier(soft, *carrier);
			const R3Vector shellCenter = r3RigidBody_CenterOfMass(carrier->handle);
			const bool nativeSurface = Valid(soft->deformable);
			const std::vector<R3ColliderHandle> surface = nativeSurface ?
				std::vector<R3ColliderHandle>{soft->deformable} : carrier->colliders;
			std::unordered_set<uint32_t> activeDents;
			std::vector<R3ContactPair> pairs;
			std::vector<R3ContactPoint> points;
			std::vector<R3ContactManifold> manifolds;
			std::vector<R3SolverContact> solverContacts;
			for (R3ColliderHandle collider : surface)
			{
				pairs.resize(r3Collider_ContactPairs(collider, nullptr, 0));
				if (pairs.empty())
					continue;
				const size_t count = r3Collider_ContactPairs(collider, pairs.data(), pairs.size());
				if (count > pairs.size())
					continue;
				const R3Pose pose = r3Collider_Position(collider);
				for (size_t p = 0; p < count; p++)
				{
					const R3ContactPair& pair = pairs[p];
					const bool first = Same(pair.collider1, collider);
					const R3ColliderHandle other = first ? pair.collider2 : pair.collider1;
					if (!Valid(other))
						continue;
					const uint32_t key = ColliderKey(other);
					if (activeDents.count(key) != 0)
						continue;

					const int sign = first ? -1 : 1;
					const uint32_t otherId = BodyIdOfCollider(world, other);
					const Body* otherBody = world->Find(otherId);
					const R3Vector otherCenter = otherBody != nullptr ? r3RigidBody_CenterOfMass(otherBody->handle) : V(0, 0, 0);
					const float contactDistance = std::max(soft->radius * 2.0f, 0.02f);
					float bestDepth = contactDistance;
					float bestSpeed = 0.0f;
					bool hasContact = false;
					R3Vector bestPoint{}, bestNormal{};
					const auto considerContact = [&](R3Vector at, R3Vector normal, float distance)
					{
						if (!std::isfinite(distance) || distance > contactDistance)
							return;
						hasContact = true;
						const R3Vector inward = Scale(normal, (float)sign);
						const R3Vector shellVelocity = Add(carrier->prevLinear, Cross(carrier->prevAngular, Sub(at, shellCenter)));
						R3Vector otherVelocity = V(0, 0, 0);
						if (otherBody != nullptr)
							otherVelocity = Add(otherBody->prevLinear, Cross(otherBody->prevAngular, Sub(at, otherCenter)));
						float speed = Dot(Sub(otherVelocity, shellVelocity), inward);
						if (otherBody != nullptr && otherBody->motion == 2)
						{
							// The soft contact can reach the narrow phase a step after Rapier stopped the impact.
							speed = std::max(speed, Dot(Sub(otherBody->prevPrevLinear, shellVelocity), inward));
							speed = std::max(speed, Dot(Sub(otherBody->prevPrevPrevLinear, shellVelocity), inward));
						}
						if (speed <= soft->dentSpeed || distance > bestDepth)
							return;
						bestDepth = distance;
						bestSpeed = speed;
						bestPoint = at;
						bestNormal = inward;
					};
					if (nativeSurface)
					{
						// Rapier resolves the triangle's contact anchors into world-space surface
						// points. The geometric points alone can be relative to a subshape.
						manifolds.resize(r3ContactManifolds(collider, other, nullptr, 0));
						const size_t manifoldCount = r3ContactManifolds(collider, other, manifolds.data(), manifolds.size());
						for (size_t m = 0; m < std::min(manifoldCount, manifolds.size()); m++)
						{
							const R3ContactManifold& manifold = manifolds[m];
							if (manifold.num_solver_contacts == 0)
								continue;
							solverContacts.resize(manifold.num_solver_contacts);
							const size_t contactCount = r3SolverContacts(collider, other, m, solverContacts.data(), solverContacts.size());
							for (size_t k = 0; k < std::min(contactCount, solverContacts.size()); k++)
							{
								const R3SolverContact& contact = solverContacts[k];
								considerContact(first ? contact.point1 : contact.point2, manifold.normal, contact.distance);
							}
						}
					}
					else
					{
						points.resize(r3ContactPoints(collider, other, nullptr, 0));
						const size_t pointCount = r3ContactPoints(collider, other, points.data(), points.size());
						for (size_t k = 0; k < std::min(pointCount, points.size()); k++)
						{
							const R3ContactPoint& point = points[k];
							const R3Vector localPoint = first ? point.local_p1 : point.local_p2;
							considerContact(Add(pose.translation, QRot(pose.rotation, localPoint)), point.normal, point.distance);
						}
					}
					if (hasContact && (soft->dentedContacts.count(key) != 0 ||
						(Length(bestNormal) >= 1.0e-5f && DentShell(soft, *carrier, otherBody, bestPoint, bestNormal, bestSpeed))))
						activeDents.insert(key);
				}
			}
			soft->dentedContacts.swap(activeDents);
		}
	}

	void UpdateTorn(World* world)
	{
		if (world->events == nullptr)
			return;
		const size_t count = r3EventCollector_TearEventCount(world->events);
		for (size_t i = 0; i < count; i++)
		{
			R3SoftBodyTearEvent* event = r3EventCollector_TearEvent(world->events, i);
			if (event == nullptr)
				continue;
			const R3SoftBodyHandle handle = r3SoftBodyTearEvent_SoftBody(event);
			for (auto& entry : world->softBodies)
			{
				if (Same(entry.second->handle, handle))
					entry.second->torn = true;
			}
			r3FreeSoftBodyTearEvent(event);
		}
	}
}

void tn_rapier_soft_update_after_step(World* world)
{
	UpdateShellDents(world);
	UpdateTorn(world);
}

// =====================================================================================================================
// Ropes
// =====================================================================================================================

uint32_t tn_rapier_rope_create(void* raw, const float* positions, uint32_t count, const float* pinned,
	float totalMass, float stretch, float bend, float damping, float radius, float friction, int32_t iterations,
	uint32_t memberships, uint32_t filter, uint32_t group, const float center[3],
	uint64_t userData)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || positions == nullptr || count < 2)
		return NoBody;
	const R3Vector offset = V(center);
	std::vector<R3Vector> worldPositions((size_t)count);
	for (uint32_t i = 0; i < count; i++)
		worldPositions[i] = Add(V(&positions[i * 3]), offset);
	std::vector<R3Edge> edges;
	edges.reserve(count > 0 ? count - 1 : 0);
	for (uint32_t i = 0; i + 1 < count; i++)
		edges.push_back(R3Edge{i, i + 1});
	std::vector<R3Edge> bendEdges;
	for (uint32_t i = 0; i + 2 < count; i++)
		bendEdges.push_back(R3Edge{i, i + 2});
	std::vector<uint32_t> pinnedIndices;
	if (pinned != nullptr)
	{
		for (uint32_t i = 0; i < count; i++)
		{
			if (pinned[i] >= 0.5f)
				pinnedIndices.push_back(i);
		}
	}
	R3SoftBodyDesc desc = r3DefaultSoftBodyDesc();
	desc.kind = R3_SOFT_DESC_PARTICLES;
	desc.positions = R3VectorView{worldPositions.data(), worldPositions.size()};
	desc.edges = R3EdgeView{edges.data(), edges.size()};
	desc.wire = desc.edges;
	if (!bendEdges.empty())
		desc.bendEdges = R3EdgeView{bendEdges.data(), bendEdges.size()};
	if (!pinnedIndices.empty())
		desc.pinned = R3IndexView{pinnedIndices.data(), pinnedIndices.size()};
	desc.particleMass = std::max(totalMass, 0.001f) / (float)std::max((size_t)count - pinnedIndices.size(), size_t{1});
	desc.particleRadius = R3OptionalReal{1, std::max(radius, 0.001f)};
	desc.gravityScale = 1;
	desc.linearDamping = std::max(damping, 0.0f);
	desc.canSleep = 1;
	desc.collisionEnabled = 1;
	desc.collider.friction = std::max(friction, 0.0f);
	desc.collider.collisionGroups = R3InteractionGroups{memberships, filter, 0};
	desc.collider.solverGroups = desc.collider.collisionGroups;
	desc.collider.activeHooks = R3_FILTER_CONTACT_PAIRS;
	desc.additionalPgsIterations = (size_t)(iterations > 0 ? std::clamp(iterations, 1, 32) : 3);
	desc.material = r3DefaultSoftBodyMaterial();
	const float frequency = std::clamp(1.0f / std::sqrt(std::max(stretch, 1.0e-9f)), 1.0f, 200.0f);
	const float bendFrequency = std::clamp(1.0f / std::sqrt(std::max(bend, 1.0e-9f)), 1.0f, 200.0f);
	desc.material.edgeSoftness = R3SpringCoefficients{frequency, std::clamp(damping, 0.0f, 1.0f)};
	desc.material.bendSoftness = R3SpringCoefficients{bendFrequency, std::clamp(damping, 0.0f, 1.0f)};
	const uint32_t id = AllocateId(world, NoBody);
	desc.userData = R3UserData{id, 0};
	const R3SoftBodyHandle handle = r3InsertSoftBody(world->world, &desc);
	if (!Valid(handle))
		return NoBody;
	SoftBody* soft = new SoftBody();
	soft->handle = handle;
	soft->count = (int32_t)count;
	soft->userData = userData;
	soft->kind = 4;
	soft->collisionInfo.group = group;
	soft->collisionInfo.motionClass = 1;
	soft->totalMass = std::max(totalMass, 0.001f);
	soft->particleMass = desc.particleMass;
	soft->radius = std::max(radius, 0.001f);
	soft->restLocal.resize((size_t)count);
	for (uint32_t i = 0; i < count; i++)
		soft->restLocal[i] = V(&positions[i * 3]);
	MatIdentity(soft->lastObject);
	world->softBodies[id] = soft;
	r3SoftBody_WakeUp(handle);
	world->MarkQueryFull();
	return id;
}

void* tn_rapier_rope_tie(void* raw, uint32_t bodyA, const float pointA[3], uint32_t bodyB,
	const float pointB[3], float length)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || length <= 0.0f)
		return nullptr;
	Body* a = world->Find(bodyA);
	Body* b = world->Find(bodyB);
	RopeTie* tie = new RopeTie();
	R3RigidBodyHandle ha{}, hb{};
	if (a != nullptr)
		ha = a->handle;
	else
	{
		R3RigidBodyDesc anchor = r3FixedRigidBodyDesc();
		const float identityRotation[4] = {0, 0, 0, 1};
		anchor.position = Pose(pointA, identityRotation);
		ha = r3InsertRigidBody(world->world, &anchor);
		if (!Valid(ha))
		{
			delete tie;
			return nullptr;
		}
		tie->anchor = ha;
		tie->hasAnchor = true;
	}
	if (b != nullptr)
		hb = b->handle;
	else
	{
		R3RigidBodyDesc anchor = r3FixedRigidBodyDesc();
		const float identityRotation[4] = {0, 0, 0, 1};
		anchor.position = Pose(pointB, identityRotation);
		hb = r3InsertRigidBody(world->world, &anchor);
		if (!Valid(hb))
		{
			if (tie->hasAnchor)
				r3RemoveRigidBody(tie->anchor, 1);
			delete tie;
			return nullptr;
		}
		tie->anchor = hb;
		tie->hasAnchor = true;
	}
	R3Pose poseA = r3RigidBody_Position(ha);
	R3Pose poseB = r3RigidBody_Position(hb);
	R3JointDesc desc = r3RopeJointDesc(length);
	// Local anchors: the world points expressed in each body's frame.
	const R3Rotation qa = QConj(poseA.rotation), qb = QConj(poseB.rotation);
	const R3Vector localA = QRot(qa, Sub(V(pointA), poseA.translation));
	const R3Vector localB = QRot(qb, Sub(V(pointB), poseB.translation));
	r3JointDesc_SetLocalAnchor1(&desc, localA);
	r3JointDesc_SetLocalAnchor2(&desc, localB);
	tie->joint = r3InsertImpulseJoint(ha, hb, &desc);
	if (!Valid(tie->joint))
	{
		if (tie->hasAnchor)
			r3RemoveRigidBody(tie->anchor, 1);
		delete tie;
		return nullptr;
	}
	world->ropeTies[(uint32_t)(uintptr_t)tie] = tie;
	return tie;
}

void tn_rapier_rope_untie(void* raw, void* tieRaw)
{
	World* world = static_cast<World*>(raw);
	RopeTie* tie = static_cast<RopeTie*>(tieRaw);
	if (world == nullptr || tie == nullptr)
		return;
	if (Valid(tie->joint))
		r3RemoveImpulseJoint(tie->joint, 0);
	if (tie->hasAnchor && Valid(tie->anchor))
		r3RemoveRigidBody(tie->anchor, 1);
	world->ropeTies.erase((uint32_t)(uintptr_t)tie);
	delete tie;
}

float tn_rapier_rope_pull(void* raw, void* tieRaw, float step)
{
	(void)raw;
	RopeTie* tie = static_cast<RopeTie*>(tieRaw);
	if (tie == nullptr || !Valid(tie->joint))
		return 0.0f;
	const R3JointImpulses impulses = r3ImpulseJoint_Impulses(tie->joint);
	float magnitude = Length(impulses.linear);
	for (float value : impulses.limits)
		magnitude = std::max(magnitude, std::fabs(value));
	for (float value : impulses.motors)
		magnitude = std::max(magnitude, std::fabs(value));
	return magnitude / std::max(step, 1.0e-6f);
}

void tn_rapier_rope_wind(void* raw, uint32_t body, const float* wind, float radius, float drag,
	float turbulence, float time, float step)
{
	World* world = static_cast<World*>(raw);
	SoftBody* soft = SoftOf(world, body);
	if (soft == nullptr || !Valid(soft->handle) || wind == nullptr || drag <= 0.0f || step <= 0.0f)
		return;
	std::vector<R3Vector> positions((size_t)soft->count);
	std::vector<R3Vector> velocities((size_t)soft->count);
	const size_t count = r3SoftBody_ParticlePositions(soft->handle, positions.data(), positions.size());
	r3SoftBody_ParticleVelocities(soft->handle, velocities.data(), velocities.size());
	if (count < 2)
		return;
	const float density = 1.2f, cylinder = 1.2f;
	const R3Vector air = V(wind);
	const float effectiveRadius = radius > 0.0f ? radius : soft->radius;
	for (size_t i = 0; i < count; i++)
	{
		const R3Vector before = positions[i > 0 ? i - 1 : i];
		const R3Vector after = positions[i + 1 < count ? i + 1 : i];
		R3Vector tangent = Sub(after, before);
		const float length = Length(tangent);
		if (length < 1.0e-6f)
			continue;
		const float span = length * ((i == 0 || i + 1 == count) ? 1.0f : 0.5f);
		tangent = Scale(tangent, 1.0f / length);
		R3Vector localAir = air;
		if (turbulence > 0.0f)
		{
			const float phase = Dot(positions[i], V(2.1f, 1.7f, 2.3f)) + time * 3.1f;
			localAir = Scale(localAir, 1.0f + turbulence * 0.25f * std::sin(phase));
		}
		R3Vector across = Sub(localAir, velocities[i]);
		across = Sub(across, Scale(tangent, Dot(tangent, across)));
		const R3Vector impulse = Scale(across, 0.5f * density * cylinder * drag * 2.0f * effectiveRadius * span *
			Length(across) * step);
		ApplyDragImpulse(soft, i, impulse, across);
	}
	r3SoftBody_WakeUp(soft->handle);
}

// =====================================================================================================================
// Vehicles
// =====================================================================================================================

namespace
{
	bool BuildVehicleController(World* world, Vehicle* vehicle)
	{
		if (world == nullptr || world->world == nullptr || vehicle == nullptr || vehicle->wheels.empty())
			return false;
		if (vehicle->controller != nullptr)
		{
			r3FreeDynamicRayCastVehicleController(vehicle->controller);
			vehicle->controller = nullptr;
		}
		vehicle->controller = r3NewDynamicRayCastVehicleController(vehicle->chassis);
		if (vehicle->controller == nullptr)
			return false;
		r3DynamicRayCastVehicleController_SetAxes(vehicle->controller, AxisIndex(vehicle->up), AxisIndex(vehicle->forward));
		const R3Vector down = Scale(vehicle->up, -1.0f);
		const R3Vector axle = Normalize(Cross(vehicle->forward, vehicle->up));
		vehicle->lastRotation.clear();
		vehicle->wheelSpeed.clear();
		vehicle->steer.clear();
		for (const TnRapierWheel& wheel : vehicle->wheels)
		{
			R3WheelTuning tuning = r3DefaultWheelTuning();
			tuning.suspension_stiffness = std::max(wheel.stiffness, 0.0f);
			tuning.suspension_compression = std::max(wheel.compression, 0.0f);
			tuning.suspension_damping = std::max(wheel.damping, 0.0f);
			tuning.max_suspension_force = wheel.maxForce > 0.0f ? wheel.maxForce : 1.0e7f;
			const R3Vector connection = V(wheel.position);
			const size_t index = r3DynamicRayCastVehicleController_AddWheel(vehicle->controller, connection, down, axle,
				std::max(wheel.restLength, 0.05f) + std::max(wheel.radius, 0.05f), std::max(wheel.radius, 0.05f), &tuning);
			if (index == SIZE_MAX)
				break;
			vehicle->lastRotation.push_back(0.0f);
			vehicle->wheelSpeed.push_back(0.0f);
			vehicle->steer.push_back(0.0f);
		}
		return !vehicle->lastRotation.empty();
	}
}

void* tn_rapier_vehicle_create(void* raw, uint32_t chassis, const TnRapierWheel* wheels, int32_t wheelCount,
	const float up[3], const float forward[3], float maxTorque, float minRPM, float maxRPM,
	const float* gearRatios, int32_t gearCount, float reverseRatio)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || wheels == nullptr || wheelCount <= 0)
		return nullptr;
	Body* body = world->Find(chassis);
	if (body == nullptr || !Valid(body->handle))
		return nullptr;
	Vehicle* vehicle = new Vehicle();
	vehicle->chassis = body->handle;
	vehicle->chassisId = chassis;
	vehicle->up = Normalize(V(up));
	vehicle->forward = Normalize(V(forward));
	if (Length(vehicle->up) < 0.5f)
		vehicle->up = V(0, 1, 0);
	if (Length(vehicle->forward) < 0.5f)
		vehicle->forward = V(0, 0, 1);
	vehicle->maxTorque = std::max(maxTorque, 0.0f);
	vehicle->minRPM = std::max(minRPM, 0.0f);
	vehicle->maxRPM = std::max(maxRPM, vehicle->minRPM + 1.0f);
	vehicle->reverseRatio = std::max(reverseRatio, 0.1f);
	for (int32_t i = 0; i < gearCount; i++)
		vehicle->gears.push_back(std::max(gearRatios[i], 0.1f));
	vehicle->ratio = vehicle->gears.empty() ? 1.0f : vehicle->gears[0];
	for (int32_t i = 0; i < wheelCount; i++)
		vehicle->wheels.push_back(wheels[i]);
	if (!BuildVehicleController(world, vehicle))
	{
		if (vehicle->controller != nullptr)
			r3FreeDynamicRayCastVehicleController(vehicle->controller);
		delete vehicle;
		return nullptr;
	}
	world->vehicles[(uint32_t)(uintptr_t)vehicle] = vehicle;
	return vehicle;
}

void tn_rapier_vehicle_destroy(void* raw, void* vehicleRaw)
{
	World* world = static_cast<World*>(raw);
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	if (world == nullptr || vehicle == nullptr)
		return;
	if (vehicle->controller != nullptr)
		r3FreeDynamicRayCastVehicleController(vehicle->controller);
	world->vehicles.erase((uint32_t)(uintptr_t)vehicle);
	delete vehicle;
}

void tn_rapier_vehicle_set_input(void* raw, void* vehicleRaw, float forward, float right, float brake,
	float handBrake)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	if (vehicle == nullptr)
		return;
	vehicle->inputForward = std::clamp(forward, -1.0f, 1.0f);
	vehicle->inputRight = std::clamp(right, -1.0f, 1.0f);
	vehicle->inputBrake = std::clamp(brake, 0.0f, 1.0f);
	vehicle->inputHandBrake = std::clamp(handBrake, 0.0f, 1.0f);
}

int32_t tn_rapier_vehicle_wheel_count(void* raw, void* vehicleRaw)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	return vehicle != nullptr ? (int32_t)vehicle->wheels.size() : 0;
}

int32_t tn_rapier_vehicle_wheel_contact(void* raw, void* vehicleRaw, int32_t index, float point[3],
	float normal[3], uint32_t* body)
{
	World* world = static_cast<World*>(raw);
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	if (world == nullptr || vehicle == nullptr || index < 0 || index >= (int32_t)vehicle->wheels.size())
		return 0;
	R3WheelState state;
	const size_t count = r3DynamicRayCastVehicleController_Wheels(vehicle->controller, &state, 1);
	(void)count;
	// Fetch the requested wheel from the full list.
	std::vector<R3WheelState> states(vehicle->wheels.size());
	r3DynamicRayCastVehicleController_Wheels(vehicle->controller, states.data(), states.size());
	if (index >= (int32_t)states.size())
		return 0;
	state = states[index];
	if (!state.is_in_contact)
		return 0;
	Out(point, state.contact_point);
	Out(normal, state.contact_normal);
	if (body != nullptr)
	{
		*body = NoBody;
		if (Valid(state.ground_object))
		{
			const R3RigidBodyHandle parent = r3Collider_Parent(state.ground_object);
			if (Valid(parent))
				*body = (uint32_t)r3RigidBody_UserData(parent).low;
		}
	}
	return 1;
}

static R3WheelState WheelState(Vehicle* vehicle, int32_t index)
{
	R3WheelState state = R3WheelState{};
	if (vehicle == nullptr || index < 0 || vehicle->controller == nullptr)
		return state;
	std::vector<R3WheelState> states(vehicle->wheels.size());
	const size_t read = r3DynamicRayCastVehicleController_Wheels(vehicle->controller, states.data(), states.size());
	if ((size_t)index < read)
		state = states[(size_t)index];
	return state;
}

float tn_rapier_vehicle_suspension(void* raw, void* vehicleRaw, int32_t index)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	if (vehicle == nullptr || index < 0 || index >= (int32_t)vehicle->wheels.size())
		return 0.0f;
	// Rapier's length includes the radius it added to the ray; the engine expects the suspension alone.
	return std::max(WheelState(vehicle, index).suspension_length - vehicle->wheels[(size_t)index].radius, 0.0f);
}

float tn_rapier_vehicle_wheel_rotation(void* raw, void* vehicleRaw, int32_t index)
{
	(void)raw;
	return WheelState(static_cast<Vehicle*>(vehicleRaw), index).rotation;
}

float tn_rapier_vehicle_wheel_steer(void* raw, void* vehicleRaw, int32_t index)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	return vehicle != nullptr && index >= 0 && index < (int32_t)vehicle->steer.size() ? vehicle->steer[(size_t)index] : 0.0f;
}

void tn_rapier_vehicle_wheel_transform(void* raw, void* vehicleRaw, int32_t index, float* matrix, float* spin)
{
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	if (matrix == nullptr)
		return;
	for (int i = 0; i < 16; i++)
		matrix[i] = 0.0f;
	matrix[0] = matrix[5] = matrix[10] = matrix[15] = 1.0f;
	R3WheelState state = WheelState(vehicle, index);
	if (spin != nullptr)
		*spin = state.rotation;
	if (vehicle == nullptr)
		return;
	const R3Rotation chassis = r3RigidBody_Rotation(vehicle->chassis);
	const R3Vector axle = Normalize(state.axle);
	R3Rotation wheel = chassis;
	if (Length(axle) > 0.5f)
	{
		const float half = state.rotation * 0.5f;
		const R3Rotation turn{axle.x * std::sin(half), axle.y * std::sin(half), axle.z * std::sin(half), std::cos(half)};
		wheel = QMul(chassis, turn);
	}
	const float xx = wheel.x * wheel.x, yy = wheel.y * wheel.y, zz = wheel.z * wheel.z;
	const float xy = wheel.x * wheel.y, xz = wheel.x * wheel.z, yz = wheel.y * wheel.z;
	const float wx = wheel.w * wheel.x, wy = wheel.w * wheel.y, wz = wheel.w * wheel.z;
	matrix[0] = 1 - 2 * (yy + zz);
	matrix[1] = 2 * (xy + wz);
	matrix[2] = 2 * (xz - wy);
	matrix[4] = 2 * (xy - wz);
	matrix[5] = 1 - 2 * (xx + zz);
	matrix[6] = 2 * (yz + wx);
	matrix[8] = 2 * (xz + wy);
	matrix[9] = 2 * (yz - wx);
	matrix[10] = 1 - 2 * (xx + yy);
	// Rapier's ray length included the radius, so its wheel centre sits a radius too low for the engine's visuals.
	const R3Vector lift = Scale(Normalize(state.suspension), vehicle->wheels[(size_t)index].radius);
	const R3Vector shown = Sub(state.center, lift);
	matrix[12] = shown.x;
	matrix[13] = shown.y;
	matrix[14] = shown.z;
}

float tn_rapier_vehicle_engine_rpm(void* raw, void* vehicleRaw)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	return vehicle != nullptr ? vehicle->rpm : 0.0f;
}

int32_t tn_rapier_vehicle_gear(void* raw, void* vehicleRaw)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	return vehicle != nullptr ? vehicle->gear : 0;
}

float tn_rapier_vehicle_ratio(void* raw, void* vehicleRaw)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	return vehicle != nullptr ? vehicle->ratio : 0.0f;
}

float tn_rapier_vehicle_wheel_speed(void* raw, void* vehicleRaw, int32_t index)
{
	(void)raw;
	Vehicle* vehicle = static_cast<Vehicle*>(vehicleRaw);
	return vehicle != nullptr && index >= 0 && index < (int32_t)vehicle->wheelSpeed.size() ? vehicle->wheelSpeed[(size_t)index] : 0.0f;
}

// =====================================================================================================================
// Navigation geometry
// =====================================================================================================================

int32_t tn_rapier_collect_geometry(void* raw, const float minimum[3], const float maximum[3],
	TnRapierTriangleCallback callback, void* user)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || callback == nullptr)
		return 0;
	const R3Vector lo = V(minimum), hi = V(maximum);
	size_t floats = 0;
	std::vector<R3Vector> vertices;
	std::vector<uint32_t> indices;
	for (const auto& entry : world->bodies)
	{
		const Body& body = entry.second;
		if (body.motion != 0)
			continue;
		for (R3ColliderHandle collider : body.colliders)
		{
			if (!Valid(collider))
				continue;
			R3SharedShape* shared = r3Collider_CloneShape(collider);
			if (shared == nullptr)
				continue;
			R3TriMeshData* mesh = r3SharedShape_ToTrimesh(shared, 12, 6);
			if (mesh != nullptr)
			{
				size_t vertexCount = r3TriMeshData_Vertices(mesh, nullptr, 0);
				size_t indexCount = r3TriMeshData_Indices(mesh, nullptr, 0);
				vertices.resize(vertexCount);
				indices.resize(indexCount);
				vertexCount = r3TriMeshData_Vertices(mesh, vertices.data(), vertices.size());
				indexCount = r3TriMeshData_Indices(mesh, indices.data(), indices.size());
				const R3Pose pose = r3Collider_Position(collider);
				for (size_t i = 0; i < vertexCount; i++)
					vertices[i] = Add(pose.translation, QRot(pose.rotation, vertices[i]));
				for (size_t i = 0; i + 2 < indexCount; i += 3)
				{
					const R3Vector a = vertices[indices[i]];
					const R3Vector b = vertices[indices[i + 1]];
					const R3Vector c = vertices[indices[i + 2]];
					const R3Vector boxMin = V(std::min({a.x, b.x, c.x}), std::min({a.y, b.y, c.y}),
						std::min({a.z, b.z, c.z}));
					const R3Vector boxMax = V(std::max({a.x, b.x, c.x}), std::max({a.y, b.y, c.y}),
						std::max({a.z, b.z, c.z}));
					if (boxMax.x < lo.x || boxMin.x > hi.x || boxMax.y < lo.y || boxMin.y > hi.y ||
						boxMax.z < lo.z || boxMin.z > hi.z)
						continue;
					if (floats + 9 > MaxGeometryFloats)
					{
						r3FreeTriMeshData(mesh);
						r3FreeSharedShape(shared);
						return 0;
					}
					const float triangle[9] = {a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z};
					callback(user, triangle);
					floats += 9;
				}
				r3FreeTriMeshData(mesh);
			}
			r3FreeSharedShape(shared);
		}
	}
	return 1;
}


// =====================================================================================================================
// Exact snapshots
// =====================================================================================================================

namespace
{
	const uint32_t SnapshotMagic = 0x31525053; // "SPR1"
	const uint32_t SnapshotVersion = 1;

	struct RapierSnapshot
	{
		std::vector<uint8_t> data;
	};

	bool SnapshotValid(const RapierSnapshot* snapshot)
	{
		if (snapshot == nullptr || snapshot->data.size() < 16)
			return false;
		uint32_t magic = 0, version = 0;
		std::memcpy(&magic, snapshot->data.data(), 4);
		std::memcpy(&version, snapshot->data.data() + 4, 4);
		return magic == SnapshotMagic && version == SnapshotVersion;
	}

	uint32_t BodyEngineId(R3RigidBodyHandle handle)
	{
		return Valid(handle) ? (uint32_t)r3RigidBody_UserData(handle).low : NoBody;
	}

	bool RemapWorld(World* world, const RapierSnapshot* snapshot)
	{
		if (world == nullptr || !SnapshotValid(snapshot))
			return false;
		R3World* fresh = r3DeserializeWorld(snapshot->data.data() + 16, snapshot->data.size() - 16);
		if (fresh == nullptr)
			return false;

		std::vector<R3RigidBodyHandle> bodyHandles(1024);
		size_t bodyCount = r3RigidBodyHandles(fresh, bodyHandles.data(), bodyHandles.size());
		if (bodyCount > bodyHandles.size())
		{
			bodyHandles.resize(bodyCount);
			bodyCount = r3RigidBodyHandles(fresh, bodyHandles.data(), bodyHandles.size());
		}
		std::unordered_map<uint32_t, R3RigidBodyHandle> byId;
		for (size_t i = 0; i < bodyCount; i++)
		{
			const uint32_t id = BodyEngineId(bodyHandles[i]);
			if (id != NoBody)
				byId[id] = bodyHandles[i];
		}

		// Every tracked body and soft body must be in the snapshot, or it belongs to another body set.
		for (const auto& entry : world->bodies)
		{
			if (byId.find(entry.first) == byId.end())
			{
				r3FreeWorld(fresh);
				return false;
			}
		}
		std::vector<R3SoftBodyHandle> softHandles(256);
		size_t softCount = r3SoftBodyHandles(fresh, softHandles.data(), softHandles.size());
		if (softCount > softHandles.size())
		{
			softHandles.resize(softCount);
			softCount = r3SoftBodyHandles(fresh, softHandles.data(), softHandles.size());
		}
		std::unordered_map<uint32_t, R3SoftBodyHandle> softById;
		for (size_t i = 0; i < softCount; i++)
		{
			const R3RigidBodyHandle root = r3SoftBody_RootBody(softHandles[i]);
			const uint32_t id = BodyEngineId(root);
			if (id != NoBody)
				softById[id] = softHandles[i];
		}
		for (const auto& entry : world->softBodies)
		{
			if (softById.find(entry.first) == softById.end())
			{
				r3FreeWorld(fresh);
				return false;
			}
		}

		R3World* old = world->world;
		// Bodies and their colliders.
		for (auto& entry : world->bodies)
		{
			Body& body = entry.second;
			body.handle = byId[entry.first];
			body.hasStepForce = false;
			body.hasStepTorque = false;
			world->MarkStepForce(entry.first, body, Length(r3RigidBody_UserForce(body.handle)) > 0.0f,
				Length(r3RigidBody_UserTorque(body.handle)) > 0.0f);
			std::vector<R3ColliderHandle> colliders(64);
			size_t colliderCount = r3RigidBody_Colliders(body.handle, colliders.data(), colliders.size());
			if (colliderCount > colliders.size())
			{
				colliders.resize(colliderCount);
				colliderCount = r3RigidBody_Colliders(body.handle, colliders.data(), colliders.size());
			}
			body.colliders.assign(colliders.begin(), colliders.begin() + std::min(colliderCount, colliders.size()));
		}
		// Soft bodies and colliders keep their arena indices, but their handles now refer to the restored world.
		world->deformableOwners.clear();
		for (auto& entry : world->softBodies)
		{
			SoftBody* soft = entry.second;
			soft->handle = softById[entry.first];
			if (soft->hasCollider)
				soft->collisionInfo.handle = r3SoftBody_RootBody(soft->handle);
			if (!Valid(soft->deformable))
				continue;
			soft->deformable.world = fresh;
			if (Valid(soft->replacedCollider))
				soft->replacedCollider.world = fresh;
			if (Body* carrier = world->Find(soft->ignoredBody))
			{
				carrier->shellSurface = soft->deformable;
				UpdateFilterHooks(*carrier);
			}
			world->deformableOwners[ColliderKey(soft->deformable)] = soft->ignoredBody;
		}
		// Characters (their controllers and shapes are world-independent).
		for (auto& entry : world->characters)
		{
			Character* character = entry.second;
			auto found = byId.find(character->bodyId);
			if (found == byId.end())
			{
				r3FreeWorld(fresh);
				return false;
			}
			character->body = found->second;
			std::vector<R3ColliderHandle> colliders(8);
			const size_t colliderCount = r3RigidBody_Colliders(character->body, colliders.data(), colliders.size());
			if (colliderCount > 0)
				character->collider = colliders[0];
		}
		// Joints: match by the pair of engine body ids, in order.
		std::vector<R3ImpulseJointHandle> jointHandles(256);
		size_t jointCount = r3ImpulseJointHandles(fresh, jointHandles.data(), jointHandles.size());
		if (jointCount > jointHandles.size())
		{
			jointHandles.resize(jointCount);
			jointCount = r3ImpulseJointHandles(fresh, jointHandles.data(), jointHandles.size());
		}
		std::unordered_map<uint64_t, std::vector<R3ImpulseJointHandle>> jointsByPair;
		for (size_t i = 0; i < jointCount; i++)
		{
			const R3JointBodies bodies = r3ImpulseJoint_Bodies(jointHandles[i]);
			const uint32_t a = BodyEngineId(bodies.body1), b = BodyEngineId(bodies.body2);
			if (a == NoBody || b == NoBody)
				continue;
			const uint64_t key = ((uint64_t)std::min(a, b) << 32) | std::max(a, b);
			jointsByPair[key].push_back(jointHandles[i]);
		}
		for (auto& entry : world->joints)
		{
			Joint* joint = entry.second;
			const uint64_t key = ((uint64_t)std::min(joint->bodyA, joint->bodyB) << 32) | std::max(joint->bodyA, joint->bodyB);
			auto found = jointsByPair.find(key);
			if (found == jointsByPair.end() || found->second.empty())
			{
				r3FreeWorld(fresh);
				return false;
			}
			joint->handle = found->second.back();
			found->second.pop_back();
		}
		// Rope ties point into the old world: drop their joints (the engine ties them again) but keep the handles
		// alive so the component's pointers stay valid.
		for (auto& entry : world->ropeTies)
		{
			RopeTie* tie = entry.second;
			if (Valid(tie->joint))
				r3RemoveImpulseJoint(tie->joint, 0);
			if (tie->hasAnchor && Valid(tie->anchor))
				r3RemoveRigidBody(tie->anchor, 1);
			tie->joint = R3ImpulseJointHandle{};
			tie->anchor = R3RigidBodyHandle{};
			tie->hasAnchor = false;
		}
		// Vehicles rebuild their controllers on the new chassis.
		for (auto& entry : world->vehicles)
		{
			Vehicle* vehicle = entry.second;
			auto found = byId.find(vehicle->chassisId);
			if (found == byId.end())
			{
				r3FreeWorld(fresh);
				return false;
			}
			vehicle->chassis = found->second;
			BuildVehicleController(world, vehicle);
		}

		world->world = fresh;
		world->MarkQueryFull();
		world->activePairList.clear();
		world->recentHits.clear();
		world->recentHitNext = 0;
		world->colliderInfo.clear();
		if (world->events != nullptr)
			r3EventCollector_Clear(world->events);
		r3FreeWorld(old);
		return true;
	}
}

void* tn_rapier_state_save(void* raw, void* reuse)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr)
		return reuse;
	R3Bytes* bytes = r3SerializeWorld(world->world);
	if (bytes == nullptr)
		return reuse;
	const R3ByteView view = r3Bytes_Data(bytes);
	RapierSnapshot* snapshot = reuse != nullptr ? static_cast<RapierSnapshot*>(reuse) : new RapierSnapshot();
	snapshot->data.resize(16 + view.count);
	const uint32_t magic = SnapshotMagic, version = SnapshotVersion;
	std::memcpy(snapshot->data.data(), &magic, 4);
	std::memcpy(snapshot->data.data() + 4, &version, 4);
	if (view.count > 0)
		std::memcpy(snapshot->data.data() + 16, view.data, view.count);
	r3FreeBytes(bytes);
	return snapshot;
}

bool tn_rapier_state_restore(void* raw, void* state)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || state == nullptr)
		return false;
	return RemapWorld(world, static_cast<const RapierSnapshot*>(state));
}

int32_t tn_rapier_state_size(void* state)
{
	RapierSnapshot* snapshot = static_cast<RapierSnapshot*>(state);
	return snapshot != nullptr ? (int32_t)snapshot->data.size() : 0;
}

void tn_rapier_state_free(void* state)
{
	if (state != nullptr)
		delete static_cast<RapierSnapshot*>(state);
}

void* tn_rapier_state_from(const uint8_t* data, int32_t size)
{
	if (data == nullptr || size < 16)
		return nullptr;
	RapierSnapshot* snapshot = new RapierSnapshot();
	snapshot->data.assign(data, data + size);
	if (!SnapshotValid(snapshot))
	{
		delete snapshot;
		return nullptr;
	}
	return snapshot;
}

void tn_rapier_state_copy(void* state, uint8_t* into, int32_t size)
{
	RapierSnapshot* snapshot = static_cast<RapierSnapshot*>(state);
	if (snapshot == nullptr || into == nullptr || size <= 0)
		return;
	const int32_t count = std::min(size, (int32_t)snapshot->data.size());
	std::memcpy(into, snapshot->data.data(), count);
}
