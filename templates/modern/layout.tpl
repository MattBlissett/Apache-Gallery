<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML+RDFa 1.0//EN" "http://www.w3.org/MarkUp/DTD/xhtml-rdfa-1.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"
	xmlns:cc="http://creativecommons.org/ns#"
	xmlns:dc="http://purl.org/dc/elements/1.1/"
	xmlns:foaf="http://xmlns.com/foaf/0.1/"
	xmlns:geopos="http://www.w3.org/2003/01/geo/wgs84_pos#"
	xmlns:og="http://ogp.me/ns#"
	xmlns:xsd="http://www.w3.org/2001/XMLSchema">
<head>
	<title>{ $TITLE }</title>

	<script type="text/javascript">
		var availablePhotoWidths = [{ $AVAILABLEWIDTHS }];
	</script>

	<meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=0.1" />
	<link rel="stylesheet" href="/ApacheGallery/modern/{ $CSS }" type="text/css"/>
	<link rel="stylesheet" href="/ApacheGallery/modern/map.css" type="text/css"/>
	<meta name="theme-color" content="#555">

	<script type="text/javascript" src="/ApacheGallery/modern/jquery-1.6.2.min.js"></script>
	<script type="text/javascript" src="/ApacheGallery/modern/OpenLayers.js"></script>
	<script type="text/javascript" src="//maps.google.com/maps/api/js?v=3.6&amp;sensor=false"></script>
	<script type="text/javascript" src="/ApacheGallery/modern/modern.js"></script>

	{ $META }
</head>

<body>
	<script type="text/javascript">var theme = "{ $CSS }";</script>
	{ $MAIN }
	<div id="footer">
		Indexed by <a href="https://github.com/MattBlissett/Apache-Gallery">Apache::Gallery</a> — Copyright © 2001–2011 Michael Legart with changes © 2012–2017 Matthew Blissett; source code available on <a href="https://github.com/MattBlissett/Apache-Gallery">GitHub</a>.
	</div>
</body>
</html>
