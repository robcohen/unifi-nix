// MongoDB initialization script for UniFi schema extraction
// Creates the unifi database and user with proper permissions

db = db.getSiblingDB('unifi');

db.createUser({
  user: 'unifi',
  pwd: 'unifi',
  roles: [
    { role: 'dbOwner', db: 'unifi' },
    { role: 'readWrite', db: 'unifi' }
  ]
});

// Also create unifi_stat database that UniFi uses
db = db.getSiblingDB('unifi_stat');

db.createUser({
  user: 'unifi',
  pwd: 'unifi',
  roles: [
    { role: 'dbOwner', db: 'unifi_stat' },
    { role: 'readWrite', db: 'unifi_stat' }
  ]
});

print('MongoDB initialized for UniFi');
