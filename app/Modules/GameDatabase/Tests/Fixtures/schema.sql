CREATE INDEX "directive_log_by_device"
  ON "directiveLogEntries" ("deviceCode", "occurredAt");

CREATE INDEX "directive_log_by_directive"
  ON "directiveLogEntries" ("directiveID", "occurredAt");

CREATE UNIQUE INDEX "directive_log_unique_event"
  ON "directiveLogEntries" ("eventID") WHERE "eventID" IS NOT NULL;

CREATE UNIQUE INDEX "operation_one_open_per_device"
  ON "operations" ("entityCode")
  WHERE "status" IN ('enqueued', 'active');

CREATE TABLE "blueprints" (
  "deviceType" TEXT PRIMARY KEY NOT NULL,
  "shortDescription" TEXT NOT NULL DEFAULT '',
  "fullDescription" TEXT NOT NULL DEFAULT '',
  "printTime" INTEGER NOT NULL DEFAULT 0,
  "features" TEXT NOT NULL DEFAULT '[]',
  "directives" TEXT NOT NULL DEFAULT '[]',
  "resources" TEXT NOT NULL DEFAULT '{}',
  "stowCapacity" INTEGER NOT NULL DEFAULT 0,
  "cargoCapacity" INTEGER NOT NULL DEFAULT 0,
  "attachCapacity" INTEGER NOT NULL DEFAULT 0,
  "queueSize" INTEGER NOT NULL DEFAULT 0,
  "strength" REAL NOT NULL DEFAULT 0,
  "currentHubs" INTEGER
) STRICT;

CREATE TABLE "bobnetChannels" (
  "name" TEXT PRIMARY KEY NOT NULL,
  "lastActive" TEXT,
  "lastReadMessageID" INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE "bobnetMessages" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "replicantName" TEXT NOT NULL DEFAULT '',
  "replicantCode" TEXT NOT NULL DEFAULT '',
  "currentStar" TEXT,
  "channel" TEXT NOT NULL DEFAULT '',
  "message" TEXT NOT NULL DEFAULT '',
  "time" TEXT NOT NULL
) STRICT;

CREATE TABLE "civilisations" (
  "speciesKey" TEXT PRIMARY KEY NOT NULL,
  "name" TEXT NOT NULL DEFAULT '',
  "speciesDescription" TEXT NOT NULL DEFAULT '',
  "government" TEXT NOT NULL DEFAULT '',
  "greeting" TEXT NOT NULL DEFAULT '',
  "homeworldType" TEXT NOT NULL DEFAULT '',
  "techAffinity" TEXT NOT NULL DEFAULT '',
  "trait" TEXT NOT NULL DEFAULT '',
  "starRegions" TEXT NOT NULL DEFAULT '[]',
  "totalReputation" INTEGER
) STRICT;

CREATE TABLE "devices" (
  "deviceCode" TEXT PRIMARY KEY NOT NULL,
  "deviceType" TEXT NOT NULL DEFAULT '',
  "replicantCode" TEXT NOT NULL DEFAULT '',
  "status" TEXT NOT NULL DEFAULT '',
  "location" TEXT,
  "locationName" TEXT,
  "operationalCapacity" REAL NOT NULL DEFAULT 0,
  "queueSize" INTEGER NOT NULL DEFAULT 0,
  "stowedInDeviceCode" TEXT,
  "controllerDeviceCode" TEXT,
  "attachedToDeviceCode" TEXT,
  "createdAt" TEXT NOT NULL,
  "availableCommands" TEXT NOT NULL DEFAULT '[]',
  "features" TEXT NOT NULL DEFAULT '[]',
  "tags" TEXT NOT NULL DEFAULT '[]',
  "detail" TEXT NOT NULL DEFAULT '{}',
  "updatedAt" TEXT NOT NULL,
  "firstSeenAt" TEXT NOT NULL
) STRICT;

CREATE TABLE "directiveLogEntries" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "directiveID" TEXT,
  "deviceCode" TEXT,
  "kind" TEXT NOT NULL,
  "summary" TEXT NOT NULL DEFAULT '',
  "step" TEXT,
  "operationID" TEXT,
  "eventID" TEXT,
  "occurredAt" TEXT NOT NULL
) STRICT;

CREATE TABLE "directives" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "kind" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "deviceCode" TEXT NOT NULL DEFAULT '',
  "targets" TEXT NOT NULL DEFAULT '[]',
  "targetIndex" INTEGER NOT NULL DEFAULT 0,
  "step" TEXT NOT NULL DEFAULT '',
  "stepStartedAt" TEXT NOT NULL,
  "returnToOrigin" INTEGER NOT NULL DEFAULT 0,
  "originDesignation" TEXT,
  "attentionReason" TEXT,
  "createdAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL
, "controllerCode" TEXT, "roamCentre" TEXT, "fleetTag" TEXT) STRICT;

CREATE TABLE "eventLogs" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "event" TEXT NOT NULL DEFAULT '',
  "category" TEXT NOT NULL DEFAULT '',
  "replicantCode" TEXT,
  "deviceCode" TEXT,
  "deviceType" TEXT,
  "star" TEXT,
  "location" TEXT,
  "version" INTEGER,
  "createdAt" TEXT,
  "receivedAt" TEXT NOT NULL,
  "provenance" TEXT NOT NULL DEFAULT 'stream',
  "isHandled" INTEGER NOT NULL DEFAULT 0,
  "matchedRoutes" TEXT,
  "payload" TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE TABLE "ftlLinks" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "a" TEXT NOT NULL,
  "b" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL
) STRICT;

CREATE TABLE "knownReplicants" (
  "replicantCode" TEXT PRIMARY KEY NOT NULL,
  "name" TEXT NOT NULL DEFAULT '',
  "isNPC" INTEGER NOT NULL DEFAULT 0,
  "directoryLocation" TEXT,
  "lastKnownLocation" TEXT,
  "lastKnownLocationName" TEXT,
  "lastSeenAt" TEXT,
  "status" TEXT,
  "experiencePoints" INTEGER NOT NULL DEFAULT 0,
  "hostedDeviceCode" TEXT,
  "detail" TEXT NOT NULL DEFAULT '{}',
  "detailFetchedAt" TEXT,
  "firstSeenAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL
) STRICT;

CREATE TABLE "locationEvents" (
  "designation" TEXT PRIMARY KEY NOT NULL,
  "location" TEXT NOT NULL DEFAULT '',
  "locationName" TEXT,
  "eventType" TEXT NOT NULL DEFAULT '',
  "title" TEXT NOT NULL DEFAULT '',
  "category" TEXT,
  "tier" INTEGER NOT NULL DEFAULT 0,
  "status" TEXT NOT NULL DEFAULT 'active',
  "broadcastMessage" TEXT,
  "eventDescription" TEXT,
  "discoveredAt" TEXT,
  "completedAt" TEXT,
  "detail" TEXT NOT NULL DEFAULT '{}',
  "firstSeenAt" TEXT NOT NULL,
  "updatedAt" TEXT NOT NULL
, "objectivesMet" INTEGER NOT NULL DEFAULT 0) STRICT;

CREATE TABLE "locationFootprints" (
  "location" TEXT PRIMARY KEY NOT NULL,
  "devices" INTEGER NOT NULL DEFAULT 0,
  "resources" INTEGER NOT NULL DEFAULT 0,
  "resourceSites" INTEGER NOT NULL DEFAULT 0,
  "locationEvents" INTEGER NOT NULL DEFAULT 0,
  "replicants" INTEGER NOT NULL DEFAULT 0,
  "fetchedAt" TEXT NOT NULL
) STRICT;

CREATE TABLE "messages" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "messageType" TEXT NOT NULL DEFAULT '',
  "title" TEXT NOT NULL DEFAULT '',
  "body" TEXT NOT NULL DEFAULT '',
  "isRead" INTEGER NOT NULL DEFAULT 0,
  "createdAt" TEXT NOT NULL
, "category" TEXT, "subcategory" TEXT) STRICT;

CREATE TABLE "operations" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "entityCode" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "source" TEXT NOT NULL,
  "startedAt" TEXT NOT NULL,
  "completesAt" TEXT,
  "lastConfirmedAt" TEXT NOT NULL,
  "detail" TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE TABLE "replicants" (
  "replicantCode" TEXT PRIMARY KEY NOT NULL,
  "name" TEXT NOT NULL DEFAULT '',
  "createdAt" TEXT NOT NULL,
  "currentStar" TEXT,
  "currentStarName" TEXT,
  "currentLocation" TEXT,
  "currentLocationName" TEXT,
  "hostedDeviceCode" TEXT,
  "experiencePoints" INTEGER NOT NULL DEFAULT 0,
  "deviceCount" INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE "siteAssays" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "body" TEXT NOT NULL DEFAULT '',
  "system" TEXT NOT NULL DEFAULT '',
  "siteType" TEXT NOT NULL DEFAULT 'salvage',
  "totals" TEXT NOT NULL DEFAULT '{}',
  "assayedAt" TEXT NOT NULL
, "depleted" INTEGER NOT NULL DEFAULT 0) STRICT;

CREATE TABLE "stars" (
  "designation" TEXT PRIMARY KEY NOT NULL,
  "spectralType" TEXT NOT NULL DEFAULT '',
  "color" TEXT NOT NULL DEFAULT '',
  "positionX" REAL NOT NULL DEFAULT 0,
  "positionY" REAL NOT NULL DEFAULT 0,
  "positionZ" REAL NOT NULL DEFAULT 0,
  "estimatedPlanets" INTEGER NOT NULL DEFAULT 0,
  "explored" INTEGER NOT NULL DEFAULT 0,
  "hasLife" INTEGER,
  "entryPoint" TEXT,
  "createdAt" TEXT NOT NULL,
  "firstVisitedAt" TEXT,
  "fullyScannedAt" TEXT
) STRICT;

CREATE TABLE "systemDetails" (
  "designation" TEXT PRIMARY KEY NOT NULL,
  "systemJSON" TEXT NOT NULL DEFAULT '',
  "recon" TEXT NOT NULL DEFAULT 'aware',
  "systemScanned" INTEGER NOT NULL DEFAULT 0,
  "hydratedAt" TEXT NOT NULL
) STRICT;
