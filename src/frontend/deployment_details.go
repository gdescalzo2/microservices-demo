package main

import (
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"cloud.google.com/go/compute/metadata"
	"github.com/sirupsen/logrus"
)

// Challenge fix: upstream wrote a global map from the goroutine below while
// request handlers read it to render pages, a data race (found by
// go test -race in CI, 2026-11-20). The map is now built locally and
// published once, atomically; readers see either nothing or the full map.
var deploymentDetails atomic.Pointer[map[string]string]
var log *logrus.Logger

// currentDeploymentDetails returns the details once loaded, nil before.
func currentDeploymentDetails() map[string]string {
	if p := deploymentDetails.Load(); p != nil {
		return *p
	}
	return nil
}

func init() {
	initializeLogger()
	// Use a goroutine to ensure loadDeploymentDetails()'s GCP API
	// calls don't block non-GCP deployments. See issue #685.
	go loadDeploymentDetails()
}

func initializeLogger() {
	log = logrus.New()
	log.Level = logrus.DebugLevel
	log.Formatter = &logrus.JSONFormatter{
		FieldMap: logrus.FieldMap{
			logrus.FieldKeyTime:  "timestamp",
			logrus.FieldKeyLevel: "severity",
			logrus.FieldKeyMsg:   "message",
		},
		TimestampFormat: time.RFC3339Nano,
	}
	log.Out = os.Stdout
}

func loadDeploymentDetails() {
	details := make(map[string]string)
	var metaServerClient = metadata.NewClient(&http.Client{})

	podHostname, err := os.Hostname()
	if err != nil {
		log.Error("Failed to fetch the hostname for the Pod", err)
	}

	podCluster, err := metaServerClient.InstanceAttributeValue("cluster-name")
	if err != nil {
		log.Error("Failed to fetch the name of the cluster in which the pod is running", err)
	}

	podZone, err := metaServerClient.Zone()
	if err != nil {
		log.Error("Failed to fetch the Zone of the node where the pod is scheduled", err)
	}

	details["HOSTNAME"] = podHostname
	details["CLUSTERNAME"] = podCluster
	details["ZONE"] = podZone
	deploymentDetails.Store(&details)

	log.WithFields(logrus.Fields{
		"cluster":  podCluster,
		"zone":     podZone,
		"hostname": podHostname,
	}).Debug("Loaded deployment details")
}
