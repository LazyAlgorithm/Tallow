// Rapier3D through the C bindings (third_party/rapier). The narrow ABI in tallow_rapier.h keeps Rapier's large
// descriptors and handle lifetimes on this side. Compiled only when the prebuilt archive for the target is present;
// the stub in tallow_rapier_stub.c keeps builds without it linking (tn_rapier_available returns 0, the provider stays
// unlisted).
#include "tallow_rapier.h"

#define RAPIER_STATIC
#include "rapier.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace
{
	const uint32_t NoBody = 0xffffffffu;
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
		uint64_t userData = 0;
	};

	struct PairKey
	{
		uint32_t a, b;
		bool operator==(const PairKey& o) const { return a == o.a && b == o.b; }
	};
	struct PairHash
	{
		size_t operator()(const PairKey& k) const
		{
			return (size_t(k.a) * 0x9e3779b1u) ^ size_t(k.b);
		}
	};
	inline uint32_t ColliderKey(R3ColliderHandle h) { return h.index ^ (h.generation * 0x9e3779b1u); }
	inline PairKey MakePair(R3ColliderHandle a, R3ColliderHandle b)
	{
		const uint32_t ka = ColliderKey(a), kb = ColliderKey(b);
		return ka <= kb ? PairKey{ka, kb} : PairKey{kb, ka};
	}

	struct ActivePair
	{
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

	struct SoftBody
	{
		R3SoftBodyHandle handle{};
		int32_t count = 0;
		R3Vector center = V(0, 0, 0);
		uint64_t userData = 0;
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
		uint32_t nextId = 1;
		bool contactEvents = false;
		uint32_t queryWorlds = 0xffffffffu;
		bool queryDirty = false;
		std::unordered_set<PairKey, PairHash> activePairKeys;
		std::vector<ActivePair> activePairList;
		std::vector<TnRapierContact> contacts;
		std::vector<HitRecord> recentHits;

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
			if (recentHits.size() >= 256)
				recentHits.erase(recentHits.begin());
			recentHits.push_back(record);
		}
	};

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
		const R3RigidBodyHandle parent = r3ReadCollider_Parent(read, collider);
		if (!Valid(parent))
			return 0;
		const uint32_t id = (uint32_t)r3ReadRigidBody_UserData(read, parent).low;
		const Body* body = c->world->Find(id);
		if (body == nullptr)
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
		const Body* a = world->Find(id1);
		const Body* b = world->Find(id2);
		if (a == nullptr || b == nullptr)
			return 1;
		if (!ShareWorld(*a, *b))
			return -1;
		if (!DebrisPasses(*a, *b))
			return -1;
		return 1;
	}

	// ---- bodies ----

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
		collider.activeHooks = R3_FILTER_CONTACT_PAIRS | R3_FILTER_INTERSECTION_PAIR;
		collider.activeEvents = R3_COLLISION_EVENTS;
		if (hasMass && mass > 0.0f)
		{
			collider.massMode = R3_MASS_TOTAL;
			collider.mass = mass;
		}
		return collider;
	}

	uint32_t AllocateId(World* world, uint32_t wanted)
	{
		if (wanted != NoBody && world->bodies.find(wanted) == world->bodies.end())
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
				const R3ContactPair pair = r3ContactPair(c1, c2);
				const bool flipped = !Same(pair.collider1, c1);
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

	void EmitContact(const World* world, R3ColliderHandle c1, R3ColliderHandle c2, int32_t kind, bool sensor,
		std::vector<TnRapierContact>& into)
	{
		const uint32_t a = BodyIdOfCollider(world, c1);
		const uint32_t b = BodyIdOfCollider(world, c2);
		if (a == NoBody || b == NoBody || a == b)
			return;
		const Body* bodyA = world->Find(a);
		const Body* bodyB = world->Find(b);
		if (bodyA == nullptr || bodyB == nullptr)
			return;
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
		Body* body = world->Find(bodyId);
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
		std::snprintf(text, sizeof(text), "Rapier %s; SIMD %u; parallel %s; enhanced determinism %s",
			r3Version(), (unsigned)features.simd_lanes, features.parallel ? "on" : "off",
			features.enhanced_determinism ? "on" : "off");
		description = text;
	}
	return description.c_str();
}

// =====================================================================================================================
// World
// =====================================================================================================================

void* tn_rapier_world_new(void)
{
	if (tn_rapier_available() == 0)
		return nullptr;
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
	if (world->queryDirty && world->world != nullptr)
	{
		// Queries read the broad phase, which Rapier refreshes on a step. A bare r3DetectCollisions before the first
		// real step leaves the world frozen, so step by a microsecond instead: it refreshes the broad phase, keeps the
		// world stepping, and advances the simulation by an amount no gameplay can notice.
		const R3Real previous = r3TimeStep(world->world);
		R3PhysicsHooks hooks;
		std::memset(&hooks, 0, sizeof(hooks));
		hooks.user_data = world;
		hooks.filter_contact_pair = &FilterPair;
		hooks.filter_intersection_pair = &FilterPair;
		r3SetTimeStep(world->world, 1.0e-6f);
		r3Step(world->world, &hooks, nullptr);
		r3SetTimeStep(world->world, previous > 0.0f ? previous : 0.0f);
		world->queryDirty = false;
	}
}

// ---- vehicles ----

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
				engineForce = vehicle->maxTorque * std::fabs(vehicle->inputForward) * std::fabs(vehicle->ratio) / radius;
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
	const R3Status status = r3Step(world->world, &hooks, world->events);
	world->queryDirty = false;
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
	for (auto& entry : world->bodies)
	{
		if (Valid(entry.second.handle))
			r3RemoveRigidBody(entry.second.handle, 1);
	}
	world->bodies.clear();
	world->activePairKeys.clear();
	world->activePairList.clear();
	world->contacts.clear();
	world->recentHits.clear();
	world->queryDirty = true;
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
		world->activePairKeys.clear();
		world->activePairList.clear();
		return 0;
	}

	// The narrow phase's pairs are the truth: a pair may have begun during the broad-phase refresh before the step,
	// which a collision-event listener would not have seen.
	std::vector<R3ContactPair> contactPairs;
	size_t capacityHint = 64;
	for (int attempt = 0; attempt < 5; attempt++)
	{
		contactPairs.resize(capacityHint);
		const size_t count = r3ContactPairs(world->world, contactPairs.data(), capacityHint);
		if (count < capacityHint || capacityHint >= 262144)
		{
			contactPairs.resize(count);
			break;
		}
		capacityHint *= 4;
	}
	std::vector<R3IntersectionPair> intersectionPairs;
	capacityHint = 32;
	for (int attempt = 0; attempt < 5; attempt++)
	{
		intersectionPairs.resize(capacityHint);
		const size_t count = r3IntersectionPairs(world->world, intersectionPairs.data(), capacityHint);
		if (count < capacityHint || capacityHint >= 262144)
		{
			intersectionPairs.resize(count);
			break;
		}
		capacityHint *= 4;
	}

	std::vector<std::pair<R3ColliderHandle, R3ColliderHandle>> current;
	std::unordered_set<PairKey, PairHash> currentKeys;
	for (const R3ContactPair& pair : contactPairs)
	{
		if (!Valid(pair.collider1) || !Valid(pair.collider2))
			continue;
		const PairKey key = MakePair(pair.collider1, pair.collider2);
		if (currentKeys.insert(key).second)
			current.emplace_back(pair.collider1, pair.collider2);
	}
	for (const R3IntersectionPair& pair : intersectionPairs)
	{
		if (!pair.intersecting || !Valid(pair.collider1) || !Valid(pair.collider2))
			continue;
		const PairKey key = MakePair(pair.collider1, pair.collider2);
		if (currentKeys.insert(key).second)
			current.emplace_back(pair.collider1, pair.collider2);
	}

	std::vector<ActivePair> now;
	now.reserve(current.size());
	for (const auto& pair : current)
	{
		const PairKey key = MakePair(pair.first, pair.second);
		const int32_t kind = world->activePairKeys.count(key) != 0 ? 2 : 0;
		const bool sensor = r3Collider_IsSensor(pair.first) || r3Collider_IsSensor(pair.second);
		EmitContact(world, pair.first, pair.second, kind, sensor, world->contacts);
		ActivePair stored;
		stored.a = pair.first;
		stored.b = pair.second;
		stored.bodyA = BodyIdOfCollider(world, pair.first);
		stored.bodyB = BodyIdOfCollider(world, pair.second);
		const Body* bodyA = world->Find(stored.bodyA);
		const Body* bodyB = world->Find(stored.bodyB);
		stored.objectA = bodyA != nullptr ? bodyA->userData : 0;
		stored.objectB = bodyB != nullptr ? bodyB->userData : 0;
		stored.sensor = sensor;
		now.push_back(stored);
	}
	for (const ActivePair& pair : world->activePairList)
	{
		const PairKey key = MakePair(pair.a, pair.b);
		if (currentKeys.count(key) != 0)
			continue;
		// The collider may have gone with its body; the stored ids still name the pair that ended.
		EmitStoredContact(pair, 1, world->contacts);
	}
	world->activePairList.swap(now);
	world->activePairKeys.swap(currentKeys);

	const int32_t count = (int32_t)world->contacts.size();
	if (out != nullptr && capacity > 0)
	{
		const int32_t copy = std::min(count, capacity);
		std::memcpy(out, world->contacts.data(), sizeof(TnRapierContact) * (size_t)copy);
	}
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
	world->queryDirty = true;
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
		if (Valid(soft->second->handle))
			r3RemoveSoftBody(soft->second->handle);
		delete soft->second;
		world->softBodies.erase(soft);
		return;
	}
	auto it = world->bodies.find(id);
	if (it == world->bodies.end())
		return;
	if (Valid(it->second.handle))
		r3RemoveRigidBody(it->second.handle, 1);
	world->bodies.erase(it);
	world->queryDirty = true;
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
		world->queryDirty = true;
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
		world->queryDirty = true;
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
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_AddForce(body->handle, V(force), 1);
}

void tn_rapier_body_add_force_at(void* raw, uint32_t id, const float force[3], const float point[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_AddForceAtPoint(body->handle, V(force), V(point), 1);
}

void tn_rapier_body_add_torque(void* raw, uint32_t id, const float torque[3])
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_AddTorque(body->handle, R3AngVector{torque[0], torque[1], torque[2]}, 1);
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
	world->queryDirty = true;
	for (R3ColliderHandle collider : body->colliders)
		r3Collider_SetCollisionGroups(collider, R3InteractionGroups{collisionMemberships, collisionFilter, 0});
}

void tn_rapier_body_set_enabled(void* raw, uint32_t id, int32_t enabled)
{
	World* world = static_cast<World*>(raw);
	Body* body = world != nullptr ? world->Find(id) : nullptr;
	if (body != nullptr && Valid(body->handle))
		r3RigidBody_SetEnabled(body->handle, enabled ? 1 : 0);
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
		const float reach = std::fabs(QRot(pose.rotation, V(half.x, 0, 0)).x * normal.x) +
			std::fabs(QRot(pose.rotation, V(0, half.y, 0)).y * normal.y) +
			std::fabs(QRot(pose.rotation, V(0, 0, half.z)).z * normal.z);
		const float plane = Dot(Sub(level, centre), normal);
		under = reach > 0.0001f ? std::clamp((reach - plane) / (reach * 2.0f), 0.0f, 1.0f) : 1.0f;
	}
	if (under <= 0.0f)
		return 0;
	const float mass = std::max(r3RigidBody_Mass(body->handle), 0.001f);
	R3Vector gravity = r3Gravity(world->world);
	const R3Vector force = Scale(gravity, -mass * std::max(buoyancy, 0.0f) * under);
	r3RigidBody_AddForceAtPoint(body->handle, force, pose.translation, 1);
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
	Body* body = world->Find(bodyId);
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
			Body* body = world->Find(bodyId);
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
		Body* body = world->Find(bodyId);
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
	for (auto it = world->recentHits.rbegin(); it != world->recentHits.rend(); ++it)
	{
		if (it->body != body || it->subshape != subshape)
			continue;
		const float distance = Dot(Sub(it->point, at), Sub(it->point, at));
		if (distance < bestDistance)
		{
			bestDistance = distance;
			best = &*it;
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

	character->controller = r3NewKinematicCharacterController();
	if (character->controller == nullptr)
	{
		r3RemoveRigidBody(character->body, 1);
		r3FreeSharedShape(character->shape);
		delete character;
		return nullptr;
	}
	r3KinematicCharacterController_SetUp(character->controller, V(0, 1, 0));
	r3KinematicCharacterController_SetOffset(character->controller, R3CharacterLength{0.01f, 0});
	r3KinematicCharacterController_SetSlide(character->controller, 1);
	r3KinematicCharacterController_SetSlopes(character->controller, character->maxSlope,
		std::max(character->maxSlope, 0.7f));
	r3KinematicCharacterController_SetSnapToGround(character->controller, 1, R3CharacterLength{0.2f, 0});
	r3KinematicCharacterController_SetAutostep(character->controller, 1, R3CharacterLength{0.3f, 0},
		R3CharacterLength{0.1f, 0}, 1);
	r3KinematicCharacterController_SetNormalNudgeFactor(character->controller, 0.01f);

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
	const R3CharacterMovement movement = r3KinematicCharacterController_MoveShape(world->world, &options,
		character->controller, deltaTime, character->shape, pose, translation);

	character->lastHits.clear();
	character->velocity = Scale(movement.translation, 1.0f / deltaTime);
	character->position = Add(character->position, movement.translation);
	r3RigidBody_SetNextKinematicTranslation(character->body, character->position);

	R3CharacterCollision collisions[32];
	const size_t count = r3KinematicCharacterController_Collisions(character->controller, collisions,
		sizeof(collisions) / sizeof(collisions[0]));
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
		Out(state->groundNormal, groundNormal);
		if (movement.grounded && groundDot >= std::cos(character->maxSlope) - 0.02f)
		{
			state->groundState = 0;
			state->groundBody = groundBody;
			if (groundBody != NoBody)
			{
				const Body* ground = world->Find(groundBody);
				if (ground != nullptr && Valid(ground->handle))
				{
					const R3Vector at = Add(character->position, V(0, -character->supportHeight, 0));
					Out(state->groundVelocity, r3RigidBody_VelocityAtPoint(ground->handle, at));
				}
			}
		}
		else if (movement.grounded)
			state->groundState = 1;
		else if (count > 0)
			state->groundState = 2;
		else
			state->groundState = 3;
	}

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
	SoftBody* SoftOf(World* world, uint32_t id)
	{
		if (world == nullptr)
			return nullptr;
		auto it = world->softBodies.find(id);
		return it == world->softBodies.end() ? nullptr : it->second;
	}
}

uint32_t tn_rapier_soft_create(void* raw, const float* positions, int32_t vertexCount, const uint32_t* triangles,
	int32_t triangleCount, const float* pinned, float totalMass, float stiffness, float damping, float friction,
	const float center[3], uint64_t userData)
{
	World* world = static_cast<World*>(raw);
	if (world == nullptr || world->world == nullptr || positions == nullptr || vertexCount < 3 || triangles == nullptr ||
		triangleCount < 1)
		return NoBody;
	const R3Vector offset = V(center);
	std::vector<R3Vector> worldPositions((size_t)vertexCount);
	for (int32_t i = 0; i < vertexCount; i++)
		worldPositions[(size_t)i] = Add(V(&positions[i * 3]), offset);
	std::vector<uint32_t> pinnedIndices;
	if (pinned != nullptr)
	{
		for (int32_t i = 0; i < vertexCount; i++)
		{
			if (pinned[i] >= 0.5f)
				pinnedIndices.push_back((uint32_t)i);
		}
	}
	R3SoftBodyDesc desc = r3DefaultSoftBodyDesc();
	desc.kind = R3_SOFT_DESC_SURFACE;
	desc.positions = R3VectorView{worldPositions.data(), worldPositions.size()};
	desc.surface = R3SurfaceElementView{reinterpret_cast<const R3Triangle*>(triangles), (size_t)triangleCount};
	desc.totalMass = R3OptionalReal{1, std::max(totalMass, 0.001f)};
	if (!pinnedIndices.empty())
		desc.pinned = R3IndexView{pinnedIndices.data(), pinnedIndices.size()};
	desc.material = r3DefaultSoftBodyMaterial();
	const float frequency = std::clamp(1.0f / std::sqrt(std::max(stiffness, 1.0e-6f)), 1.0f, 60.0f);
	desc.material.edgeSoftness = R3SpringCoefficients{frequency, std::clamp(damping, 0.0f, 1.0f)};
	desc.material.bendSoftness = R3SpringCoefficients{frequency * 0.5f, std::clamp(damping, 0.0f, 1.0f)};
	desc.material.youngModulus = 0.0f;
	desc.material.poissonRatio = 0.0f;
	(void)friction;
	const R3SoftBodyHandle handle = r3InsertSoftBody(world->world, &desc);
	if (!Valid(handle))
		return NoBody;
	SoftBody* soft = new SoftBody();
	soft->handle = handle;
	soft->count = vertexCount;
	soft->center = offset;
	soft->userData = userData;
	const uint32_t id = AllocateId(world, NoBody);
	world->softBodies[id] = soft;
	return id;
}

void tn_rapier_soft_destroy(void* raw, uint32_t body)
{
	World* world = static_cast<World*>(raw);
	SoftBody* soft = SoftOf(world, body);
	if (soft == nullptr)
		return;
	if (Valid(soft->handle))
		r3RemoveSoftBody(soft->handle);
	world->softBodies.erase(body);
	delete soft;
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
	std::vector<R3Vector> buffer((size_t)soft->count);
	const uint32_t count = (uint32_t)std::min((size_t)soft->count, (size_t)capacity);
	if (positions != nullptr)
	{
		r3SoftBody_ParticlePositions(soft->handle, buffer.data(), buffer.size());
		for (uint32_t i = 0; i < count; i++)
		{
			Out(&positions[i * 3], Sub(buffer[(size_t)i], soft->center));
		}
	}
	if (velocities != nullptr)
	{
		r3SoftBody_ParticleVelocities(soft->handle, buffer.data(), buffer.size());
		for (uint32_t i = 0; i < count; i++)
			Out(&velocities[i * 3], buffer[(size_t)i]);
	}
	return count;
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
		r3SoftBody_SetParticleKinematicTarget(soft->handle, indices[i], Add(V(&targets[i * 3]), soft->center));
	}
}

void tn_rapier_soft_set_positions(void* raw, uint32_t body, const float* positions, const float* velocities,
	uint32_t count, const float center[3])
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle))
		return;
	(void)center;
	const uint32_t limit = std::min(count, (uint32_t)soft->count);
	for (uint32_t i = 0; i < limit; i++)
	{
		r3SoftBody_SetParticlePosition(soft->handle, i, Add(V(&positions[i * 3]), soft->center));
		if (velocities != nullptr)
			r3SoftBody_SetParticleVelocity(soft->handle, i, V(&velocities[i * 3]));
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
	std::vector<R3Vector> buffer((size_t)soft->count);
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
	for (int32_t i = 0; i < soft->count; i++)
		r3SoftBody_SetParticleVelocity(soft->handle, (size_t)i, value);
	r3SoftBody_WakeUp(soft->handle);
}

void tn_rapier_soft_impulse(void* raw, uint32_t body, const float* impulse)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft != nullptr && Valid(soft->handle) && impulse != nullptr)
		r3SoftBody_ApplyImpulse(soft->handle, V(impulse), 1);
}

void tn_rapier_soft_force(void* raw, uint32_t body, const float* force)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft != nullptr && Valid(soft->handle) && force != nullptr)
		r3SoftBody_AddForce(soft->handle, V(force), 1);
}

void tn_rapier_soft_shift(void* raw, uint32_t body, const float* offset)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || offset == nullptr)
		return;
	const R3Vector delta = V(offset);
	std::vector<R3Vector> buffer((size_t)soft->count);
	const size_t count = r3SoftBody_ParticlePositions(soft->handle, buffer.data(), buffer.size());
	for (size_t i = 0; i < count; i++)
		r3SoftBody_SetParticlePosition(soft->handle, i, Add(buffer[i], delta));
	soft->center = Add(soft->center, delta);
	r3SoftBody_WakeUp(soft->handle);
}

int32_t tn_rapier_soft_bounds(void* raw, uint32_t body, float* minimum, float* maximum)
{
	SoftBody* soft = SoftOf(static_cast<World*>(raw), body);
	if (soft == nullptr || !Valid(soft->handle) || minimum == nullptr || maximum == nullptr || soft->count == 0)
		return 0;
	std::vector<R3Vector> buffer((size_t)soft->count);
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

// =====================================================================================================================
// Vehicles
// =====================================================================================================================

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
	vehicle->controller = r3NewDynamicRayCastVehicleController(body->handle);
	if (vehicle->controller == nullptr)
	{
		delete vehicle;
		return nullptr;
	}
	r3DynamicRayCastVehicleController_SetAxes(vehicle->controller, AxisIndex(vehicle->up), AxisIndex(vehicle->forward));
	const R3Vector down = Scale(vehicle->up, -1.0f);
	const R3Vector axle = Normalize(Cross(vehicle->forward, vehicle->up));
	for (int32_t i = 0; i < wheelCount; i++)
	{
		const TnRapierWheel& wheel = wheels[i];
		R3WheelTuning tuning = r3DefaultWheelTuning();
		tuning.suspension_stiffness = std::max(wheel.stiffness, 0.0f);
		tuning.suspension_compression = std::max(wheel.compression, 0.0f);
		tuning.suspension_damping = std::max(wheel.damping, 0.0f);
		tuning.max_suspension_force = wheel.maxForce > 0.0f ? wheel.maxForce : 1.0e7f;
		const R3Vector connection = V(wheel.position);
		// Rapier casts the suspension ray for rest_length and does not add the wheel radius, so the ray must span the
		// suspension plus the wheel to reach the ground with the wheel's bottom.
		const size_t index = r3DynamicRayCastVehicleController_AddWheel(vehicle->controller, connection, down, axle,
			std::max(wheel.restLength, 0.05f) + std::max(wheel.radius, 0.05f), std::max(wheel.radius, 0.05f), &tuning);
		if (index == SIZE_MAX)
			break;
		vehicle->wheels.push_back(wheel);
		vehicle->lastRotation.push_back(0.0f);
		vehicle->wheelSpeed.push_back(0.0f);
		vehicle->steer.push_back(0.0f);
	}
	if (vehicle->wheels.empty())
	{
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
