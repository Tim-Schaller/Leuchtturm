// Public values only. The CloudKit API tokens (one per environment) let
// this page read the public database of the container (encrypted live
// locations), nothing else, and only from tim-schaller.github.io.
export const config = {
  container: "iCloud.de.timschaller.leuchtturm",
  cloudKitTokens: {
    production: "04977cf054a623e89e87319b3b7670409ba6145690178821e40ee9d365634f35",
    development: "e681dba94deccdb555b74b25b094ed5b13909371e6168f65f2293d8e13f72262",
  },
  // Optional: a MapKit JS token restricted to this domain shows a map.
  mapKitToken: "",
};
