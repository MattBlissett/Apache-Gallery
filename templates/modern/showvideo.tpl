<div id="page">
	<div id="menu">{ $MENU }</div>

	<div id="directory">
		<div id="picture">
			Viewing picture (video) { $NUMBER } of { $TOTAL }<br/>
			<video controls src="{ $SRC }">
				<p>Your browser doesn't support playing this video file directly. You could try <a href="{ $SRC }">downloading it</a>.</p>
				<a href="{ $SRC }"><img src="{ $POSTER }" alt="Video thumbnail"></a>
			</video>
			Slideshow [ { $SLIDESHOW } ]
		</div>

		<div id="nav">
			<span class="nav left" width="20%">{ $BACK }</span>
			<span class="nav right" width="20%">{ $NEXT }</span>
			<span class="info">{ $PICTUREINFO }</span>
		</div>
		<div class="clear"></div>
	</div>
</div>
