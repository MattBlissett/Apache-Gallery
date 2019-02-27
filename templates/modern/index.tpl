<header id="menu">{ $MENU }</header>

<div id="directory">
	<div id="files" tabindex="1">
{ $FILES }
	</div>

	<nav id="nav">
		{ $BROWSELINKS }
	</nav>

	<div id="dircomment">
		{ $DIRCOMMENT }
	</div>
</div>

<script type="text/javascript">
	var availableTracks = [{ $AVAILABLETRACKS }];
</script>

<div id="mapcontainer" class="gallerymap">
	<div id="map" class="map"></div>
</div>

<script type="text/javascript">
	var hasMap = true;

	document.getElementById("files").focus();
</script>
