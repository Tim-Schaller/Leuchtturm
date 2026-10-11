// Package store persists devices, circles, members and invites in SQLite.
//
// The store only ever sees public keys and opaque ciphertext blobs. It never
// handles plaintext locations, names or circle keys.
package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite driver (no CGO)
)

// Sentinel errors returned by Store methods.
var (
	ErrNotFound  = errors.New("not found")
	ErrConflict  = errors.New("conflict")
	ErrForbidden = errors.New("forbidden")
	ErrInvalid   = errors.New("invalid")
	ErrLimit     = errors.New("limit reached")
)

// Roles of circle members.
const (
	RoleOwner  = "owner"
	RoleMember = "member"
)

// Options tunes limits. Zero values select defaults.
type Options struct {
	// MaxMembersPerCircle bounds circle size (default 500).
	MaxMembersPerCircle int
	// MaxActiveInvitesPerCircle bounds concurrently valid invites (default 20).
	MaxActiveInvitesPerCircle int
	// Now overrides the clock (tests).
	Now func() time.Time
}

// Store is a SQLite-backed store. It is safe for concurrent use.
type Store struct {
	db   *sql.DB
	opts Options
}

// Device is a registered device identity (public keys only).
type Device struct {
	ID           string
	SigningKey   []byte // Ed25519 public key, 32 bytes
	AgreementKey []byte // X25519 public key, 32 bytes
	CreatedAt    time.Time
}

// Member is a device's membership in a circle.
type Member struct {
	DeviceID     string
	SigningKey   []byte
	AgreementKey []byte
	Role         string
	MemberBlob   []byte // opaque ciphertext
	JoinedAt     time.Time
}

// CircleSummary is one entry of a device's circle list.
type CircleSummary struct {
	ID         string
	Epoch      int64
	Role       string
	MetaBlob   []byte // opaque ciphertext (circle name etc.)
	WrappedKey []byte // nil for members who joined via invite and saw no rotation yet
}

// CircleDetail describes a circle for one of its members.
type CircleDetail struct {
	ID           string
	Epoch        int64
	MetaBlob     []byte
	MyWrappedKey []byte
	Members      []Member
}

// Invite is a stored invite (without its secret, which the server never sees).
type Invite struct {
	ID        string
	CircleID  string
	ExpiresAt time.Time
	UsesLeft  int
}

// RedeemResult is returned to a device that successfully redeemed an invite.
type RedeemResult struct {
	CircleID  string
	Epoch     int64
	Role      string
	SealedKey []byte
}

// Open opens (and migrates) the database at path.
func Open(path string, opts Options) (*Store, error) {
	if opts.MaxMembersPerCircle <= 0 {
		opts.MaxMembersPerCircle = 500
	}
	if opts.MaxActiveInvitesPerCircle <= 0 {
		opts.MaxActiveInvitesPerCircle = 20
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	q := url.Values{}
	q.Add("_pragma", "foreign_keys(1)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "synchronous(NORMAL)")
	q.Set("_txlock", "immediate")
	dsn := "file:" + path + "?" + q.Encode()

	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	db.SetMaxOpenConns(8)
	s := &Store{db: db, opts: opts}
	if err := s.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// Ping checks database connectivity.
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

var migrations = []string{
	// version 1
	`CREATE TABLE devices (
		id TEXT PRIMARY KEY,
		signing_key BLOB NOT NULL UNIQUE,
		agreement_key BLOB NOT NULL,
		created_at INTEGER NOT NULL
	) STRICT;
	CREATE TABLE circles (
		id TEXT PRIMARY KEY,
		epoch INTEGER NOT NULL,
		meta_blob BLOB NOT NULL,
		created_at INTEGER NOT NULL
	) STRICT;
	CREATE TABLE members (
		circle_id TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
		device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
		role TEXT NOT NULL CHECK (role IN ('owner','member')),
		member_blob BLOB NOT NULL,
		wrapped_key BLOB,
		joined_at INTEGER NOT NULL,
		PRIMARY KEY (circle_id, device_id)
	) STRICT;
	CREATE INDEX members_device ON members(device_id);
	CREATE TABLE invites (
		id TEXT PRIMARY KEY,
		circle_id TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
		created_by TEXT NOT NULL,
		token_hash BLOB NOT NULL,
		sealed_key BLOB NOT NULL,
		expires_at INTEGER NOT NULL,
		uses_left INTEGER NOT NULL,
		created_at INTEGER NOT NULL
	) STRICT;
	CREATE INDEX invites_circle ON invites(circle_id);`,
}

func (s *Store) migrate(ctx context.Context) error {
	var version int
	if err := s.db.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&version); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	for i := version; i < len(migrations); i++ {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, migrations[i]); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("migration %d: %w", i+1, err)
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(`PRAGMA user_version = %d`, i+1)); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// DeviceID derives the stable device identifier from an Ed25519 public key.
// It is the first 16 bytes of SHA-256(signingKey), base64url without padding.
func DeviceID(signingKey []byte) string {
	h := sha256.Sum256(signingKey)
	return base64.RawURLEncoding.EncodeToString(h[:16])
}

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("crypto/rand failed: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

func (s *Store) nowUnix() int64 { return s.opts.Now().Unix() }

// RegisterDevice stores a device identity. It is idempotent for an identical
// key pair and returns ErrConflict if the signing key is already registered
// with a different agreement key.
func (s *Store) RegisterDevice(ctx context.Context, signingKey, agreementKey []byte) (dev Device, created bool, err error) {
	if len(signingKey) != 32 || len(agreementKey) != 32 {
		return Device{}, false, ErrInvalid
	}
	id := DeviceID(signingKey)
	now := s.nowUnix()
	res, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO devices (id, signing_key, agreement_key, created_at) VALUES (?, ?, ?, ?)`,
		id, signingKey, agreementKey, now)
	if err != nil {
		return Device{}, false, err
	}
	n, _ := res.RowsAffected()
	dev, err = s.DeviceBySigningKey(ctx, signingKey)
	if err != nil {
		return Device{}, false, err
	}
	if n == 0 && !bytes.Equal(dev.AgreementKey, agreementKey) {
		return Device{}, false, ErrConflict
	}
	return dev, n == 1, nil
}

// DeviceBySigningKey looks up a device by its Ed25519 public key.
func (s *Store) DeviceBySigningKey(ctx context.Context, signingKey []byte) (Device, error) {
	var d Device
	var created int64
	err := s.db.QueryRowContext(ctx,
		`SELECT id, signing_key, agreement_key, created_at FROM devices WHERE signing_key = ?`, signingKey).
		Scan(&d.ID, &d.SigningKey, &d.AgreementKey, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, ErrNotFound
	}
	if err != nil {
		return Device{}, err
	}
	d.CreatedAt = time.Unix(created, 0)
	return d, nil
}

// DeleteDevice removes a device and all of its memberships. Circles left
// without members are deleted. If the owner leaves a circle, the earliest
// remaining member becomes owner.
func (s *Store) DeleteDevice(ctx context.Context, deviceID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	rows, err := tx.QueryContext(ctx, `SELECT circle_id FROM members WHERE device_id = ?`, deviceID)
	if err != nil {
		return err
	}
	var circles []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			rows.Close()
			return err
		}
		circles = append(circles, c)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	for _, c := range circles {
		if err := leaveTx(ctx, tx, c, deviceID); err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE id = ?`, deviceID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return tx.Commit()
}

// CreateCircle creates a circle at epoch 1 with the caller as owner.
func (s *Store) CreateCircle(ctx context.Context, deviceID string, metaBlob, memberBlob, wrappedKey []byte) (circleID string, epoch int64, err error) {
	if len(metaBlob) == 0 || len(memberBlob) == 0 || len(wrappedKey) == 0 {
		return "", 0, ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback() //nolint:errcheck

	now := s.nowUnix()
	circleID = newID()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO circles (id, epoch, meta_blob, created_at) VALUES (?, 1, ?, ?)`, circleID, metaBlob, now); err != nil {
		return "", 0, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO members (circle_id, device_id, role, member_blob, wrapped_key, joined_at)
		 VALUES (?, ?, 'owner', ?, ?, ?)`, circleID, deviceID, memberBlob, wrappedKey, now); err != nil {
		return "", 0, err
	}
	if err := tx.Commit(); err != nil {
		return "", 0, err
	}
	return circleID, 1, nil
}

// ListCircles returns the circles a device belongs to.
func (s *Store) ListCircles(ctx context.Context, deviceID string) ([]CircleSummary, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT c.id, c.epoch, m.role, c.meta_blob, m.wrapped_key
		 FROM members m JOIN circles c ON c.id = m.circle_id
		 WHERE m.device_id = ? ORDER BY m.joined_at, m.rowid`, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CircleSummary{}
	for rows.Next() {
		var c CircleSummary
		if err := rows.Scan(&c.ID, &c.Epoch, &c.Role, &c.MetaBlob, &c.WrappedKey); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GetCircle returns a circle and its members. Non-members get ErrNotFound.
func (s *Store) GetCircle(ctx context.Context, circleID, deviceID string) (CircleDetail, error) {
	d := CircleDetail{ID: circleID}
	err := s.db.QueryRowContext(ctx,
		`SELECT c.epoch, c.meta_blob, m.wrapped_key FROM members m JOIN circles c ON c.id = m.circle_id
		 WHERE m.circle_id = ? AND m.device_id = ?`, circleID, deviceID).Scan(&d.Epoch, &d.MetaBlob, &d.MyWrappedKey)
	if errors.Is(err, sql.ErrNoRows) {
		return CircleDetail{}, ErrNotFound
	}
	if err != nil {
		return CircleDetail{}, err
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT m.device_id, dv.signing_key, dv.agreement_key, m.role, m.member_blob, m.joined_at
		 FROM members m JOIN devices dv ON dv.id = m.device_id
		 WHERE m.circle_id = ? ORDER BY m.joined_at, m.rowid`, circleID)
	if err != nil {
		return CircleDetail{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var m Member
		var joined int64
		if err := rows.Scan(&m.DeviceID, &m.SigningKey, &m.AgreementKey, &m.Role, &m.MemberBlob, &joined); err != nil {
			return CircleDetail{}, err
		}
		m.JoinedAt = time.Unix(joined, 0)
		d.Members = append(d.Members, m)
	}
	return d, rows.Err()
}

// UpdateMemberBlob replaces the caller's opaque member card.
func (s *Store) UpdateMemberBlob(ctx context.Context, circleID, deviceID string, blob []byte) error {
	if len(blob) == 0 {
		return ErrInvalid
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE members SET member_blob = ? WHERE circle_id = ? AND device_id = ?`, blob, circleID, deviceID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// UpdateCircleMeta replaces the circle's opaque metadata. Owner only.
func (s *Store) UpdateCircleMeta(ctx context.Context, circleID, deviceID string, blob []byte) error {
	if len(blob) == 0 {
		return ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck
	role, err := memberRole(ctx, tx, circleID, deviceID)
	if err != nil {
		return err
	}
	if role != RoleOwner {
		return ErrForbidden
	}
	if _, err := tx.ExecContext(ctx, `UPDATE circles SET meta_blob = ? WHERE id = ?`, blob, circleID); err != nil {
		return err
	}
	return tx.Commit()
}

// CreateInvite stores an invite. tokenHash is SHA-256 of the invite auth
// token; sealedKey is the circle key sealed under a key derived from the
// invite secret. The server never learns the secret.
func (s *Store) CreateInvite(ctx context.Context, circleID, deviceID string, tokenHash, sealedKey []byte, ttl time.Duration, maxUses int) (Invite, error) {
	if len(tokenHash) != sha256.Size || len(sealedKey) == 0 || ttl <= 0 || maxUses <= 0 {
		return Invite{}, ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Invite{}, err
	}
	defer tx.Rollback() //nolint:errcheck

	if _, err := memberRole(ctx, tx, circleID, deviceID); err != nil {
		return Invite{}, err
	}
	now := s.nowUnix()
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM invites WHERE circle_id = ? AND (expires_at <= ? OR uses_left <= 0)`, circleID, now); err != nil {
		return Invite{}, err
	}
	var active int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM invites WHERE circle_id = ?`, circleID).Scan(&active); err != nil {
		return Invite{}, err
	}
	if active >= s.opts.MaxActiveInvitesPerCircle {
		return Invite{}, ErrLimit
	}
	inv := Invite{
		ID:        newID(),
		CircleID:  circleID,
		ExpiresAt: time.Unix(now, 0).Add(ttl),
		UsesLeft:  maxUses,
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO invites (id, circle_id, created_by, token_hash, sealed_key, expires_at, uses_left, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		inv.ID, circleID, deviceID, tokenHash, sealedKey, inv.ExpiresAt.Unix(), maxUses, now); err != nil {
		return Invite{}, err
	}
	if err := tx.Commit(); err != nil {
		return Invite{}, err
	}
	return inv, nil
}

// RevokeInvite deletes an invite. Allowed for its creator and the circle owner.
func (s *Store) RevokeInvite(ctx context.Context, circleID, inviteID, deviceID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	role, err := memberRole(ctx, tx, circleID, deviceID)
	if err != nil {
		return err
	}
	var createdBy string
	err = tx.QueryRowContext(ctx, `SELECT created_by FROM invites WHERE id = ? AND circle_id = ?`, inviteID, circleID).Scan(&createdBy)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if role != RoleOwner && createdBy != deviceID {
		return ErrForbidden
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM invites WHERE id = ?`, inviteID); err != nil {
		return err
	}
	return tx.Commit()
}

// RedeemInvite adds the device to the invite's circle if token matches.
// Every failure to authenticate the invite (unknown id, expired, used up,
// wrong token) returns ErrNotFound so callers cannot probe for invites.
func (s *Store) RedeemInvite(ctx context.Context, inviteID, deviceID string, token, memberBlob []byte) (RedeemResult, error) {
	if len(token) == 0 || len(memberBlob) == 0 {
		return RedeemResult{}, ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RedeemResult{}, err
	}
	defer tx.Rollback() //nolint:errcheck

	var (
		circleID  string
		tokenHash []byte
		sealedKey []byte
		expiresAt int64
		usesLeft  int
	)
	err = tx.QueryRowContext(ctx,
		`SELECT circle_id, token_hash, sealed_key, expires_at, uses_left FROM invites WHERE id = ?`, inviteID).
		Scan(&circleID, &tokenHash, &sealedKey, &expiresAt, &usesLeft)
	if errors.Is(err, sql.ErrNoRows) {
		return RedeemResult{}, ErrNotFound
	}
	if err != nil {
		return RedeemResult{}, err
	}
	now := s.nowUnix()
	got := sha256.Sum256(token)
	if now >= expiresAt || usesLeft <= 0 || subtle.ConstantTimeCompare(got[:], tokenHash) != 1 {
		return RedeemResult{}, ErrNotFound
	}

	if _, err := memberRole(ctx, tx, circleID, deviceID); err == nil {
		return RedeemResult{}, ErrConflict
	} else if !errors.Is(err, ErrNotFound) {
		return RedeemResult{}, err
	}
	var members int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM members WHERE circle_id = ?`, circleID).Scan(&members); err != nil {
		return RedeemResult{}, err
	}
	if members >= s.opts.MaxMembersPerCircle {
		return RedeemResult{}, ErrLimit
	}
	var epoch int64
	if err := tx.QueryRowContext(ctx, `SELECT epoch FROM circles WHERE id = ?`, circleID).Scan(&epoch); err != nil {
		return RedeemResult{}, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO members (circle_id, device_id, role, member_blob, wrapped_key, joined_at)
		 VALUES (?, ?, 'member', ?, NULL, ?)`, circleID, deviceID, memberBlob, now); err != nil {
		return RedeemResult{}, err
	}
	if usesLeft-1 <= 0 {
		_, err = tx.ExecContext(ctx, `DELETE FROM invites WHERE id = ?`, inviteID)
	} else {
		_, err = tx.ExecContext(ctx, `UPDATE invites SET uses_left = uses_left - 1 WHERE id = ?`, inviteID)
	}
	if err != nil {
		return RedeemResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return RedeemResult{}, err
	}
	return RedeemResult{CircleID: circleID, Epoch: epoch, Role: RoleMember, SealedKey: sealedKey}, nil
}

// Leave removes the caller from a circle.
func (s *Store) Leave(ctx context.Context, circleID, deviceID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck
	if err := leaveTx(ctx, tx, circleID, deviceID); err != nil {
		return err
	}
	return tx.Commit()
}

// RemoveMember lets the owner remove another member and rotate the circle key
// in one atomic step. wrapped must contain a freshly wrapped key for exactly
// every remaining member, metaBlob is the circle metadata re-encrypted under
// the new key, and newEpoch must be the current epoch + 1. All outstanding
// invites of the circle are revoked because they seal the old key.
func (s *Store) RemoveMember(ctx context.Context, circleID, ownerID, targetID string, newEpoch int64, metaBlob []byte, wrapped map[string][]byte) (int64, error) {
	if len(metaBlob) == 0 {
		return 0, ErrInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck

	role, err := memberRole(ctx, tx, circleID, ownerID)
	if err != nil {
		return 0, err
	}
	if role != RoleOwner {
		return 0, ErrForbidden
	}
	if targetID == ownerID {
		return 0, ErrInvalid
	}
	if _, err := memberRole(ctx, tx, circleID, targetID); err != nil {
		return 0, err
	}

	var epoch int64
	if err := tx.QueryRowContext(ctx, `SELECT epoch FROM circles WHERE id = ?`, circleID).Scan(&epoch); err != nil {
		return 0, err
	}
	if newEpoch != epoch+1 {
		return 0, ErrConflict
	}

	rows, err := tx.QueryContext(ctx, `SELECT device_id FROM members WHERE circle_id = ? AND device_id <> ?`, circleID, targetID)
	if err != nil {
		return 0, err
	}
	remaining := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		remaining[id] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()
	if len(wrapped) != len(remaining) {
		return 0, ErrInvalid
	}
	for id, key := range wrapped {
		if !remaining[id] || len(key) == 0 {
			return 0, ErrInvalid
		}
	}

	if _, err := tx.ExecContext(ctx, `UPDATE circles SET epoch = ?, meta_blob = ? WHERE id = ? AND epoch = ?`, newEpoch, metaBlob, circleID, epoch); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM members WHERE circle_id = ? AND device_id = ?`, circleID, targetID); err != nil {
		return 0, err
	}
	for id, key := range wrapped {
		if _, err := tx.ExecContext(ctx,
			`UPDATE members SET wrapped_key = ? WHERE circle_id = ? AND device_id = ?`, key, circleID, id); err != nil {
			return 0, err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM invites WHERE circle_id = ?`, circleID); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return newEpoch, nil
}

// PurgeExpiredInvites deletes expired or used-up invites and returns how many.
func (s *Store) PurgeExpiredInvites(ctx context.Context) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM invites WHERE expires_at <= ? OR uses_left <= 0`, s.nowUnix())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// querier is satisfied by *sql.Tx.
type querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func memberRole(ctx context.Context, q querier, circleID, deviceID string) (string, error) {
	var role string
	err := q.QueryRowContext(ctx,
		`SELECT role FROM members WHERE circle_id = ? AND device_id = ?`, circleID, deviceID).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return role, err
}

// leaveTx removes a membership, promotes a new owner if needed and deletes
// the circle when it becomes empty.
func leaveTx(ctx context.Context, tx *sql.Tx, circleID, deviceID string) error {
	role, err := memberRole(ctx, tx, circleID, deviceID)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM members WHERE circle_id = ? AND device_id = ?`, circleID, deviceID); err != nil {
		return err
	}
	var remaining int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM members WHERE circle_id = ?`, circleID).Scan(&remaining); err != nil {
		return err
	}
	if remaining == 0 {
		_, err := tx.ExecContext(ctx, `DELETE FROM circles WHERE id = ?`, circleID)
		return err
	}
	if role == RoleOwner {
		_, err := tx.ExecContext(ctx,
			`UPDATE members SET role = 'owner' WHERE circle_id = ? AND device_id =
			 (SELECT device_id FROM members WHERE circle_id = ? ORDER BY joined_at, rowid LIMIT 1)`,
			circleID, circleID)
		return err
	}
	return nil
}
