<div id="page">
  <div id="title">
    { $MENU }
  </div>

  <div id="menu">
{ $BACK } - <a href="./" accesskey=u" rel="up" title="Accesskey U"><u>u</u>p</a> - { $NEXT }</div>
  <div>
    <table>
      <tr>

        <td colspan="3" id="picture">
          IMG (VID) { $NUMBER } of { $TOTAL }<br><br>
            <video controls src="{ $SRC }">
              <p>Your browser doesn't support playing this video file directly. You could try <a href="{ $SRC }">downloading it</a>.</p>
              <a href="{ $SRC }"><img src="{ $POSTER }" alt="Video thumbnail"></a>
            </video><br><br>
            [ Slideshow: { $SLIDESHOW } ]</td>
              </tr>
              { $PICTUREINFO }
      </tr>
	  <tr>
	  	<td colspan="3">
		  <div id="gallery">
		  <a href="http://apachegallery.dk/">Apache::Gallery</a> &copy; 2001-2005 Michael Legart, <a href="http://www.hestdesign.com/">Hest Design</a>

		  </div>
		</td>
	  </tr>
    </table>
  </div>
</div>
