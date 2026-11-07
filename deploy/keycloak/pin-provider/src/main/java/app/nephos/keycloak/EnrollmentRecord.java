package app.nephos.keycloak;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "NEPHOS_ENROLLMENT")
public class EnrollmentRecord {
    @Id @Column(name = "ID", length = 200)
    public String id;
    @Column(name = "KIND", nullable = false, length = 20)
    public String kind;
    @Column(name = "SUBJECT_ID", length = 36)
    public String subject;
    @Column(name = "EXPIRES_AT", nullable = false)
    public long expiresAt;
    @Column(name = "PAYLOAD", nullable = false, columnDefinition = "TEXT")
    public String payload;

    public EnrollmentRecord() {}
}
